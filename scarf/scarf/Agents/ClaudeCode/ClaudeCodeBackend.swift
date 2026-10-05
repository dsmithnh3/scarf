import Foundation
import ScarfCore

/// Claude Code implementation of Scarf's generic agent backend.
///
/// The first integration intentionally supports local Claude Code only. Remote
/// execution is not advertised until it is implemented and regression-tested
/// against Scarf's existing Hermes SSH behavior.
actor ClaudeCodeBackend: SessionScopedAgentBackend {
    typealias ExecutableResolver = @Sendable () -> String?
    typealias InstallationProbe = @Sendable (String) async -> AgentInstallationStatus
    typealias EnvironmentProvider = @Sendable () -> [String: String]

    private struct Runtime {
        let manager: ClaudeProcessManager
        let decoder: ClaudeStreamDecoder
        let incomingTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>
    }

    nonisolated let id: AgentID = .claudeCode
    nonisolated let displayName = "Claude Code"
    nonisolated let capabilities: AgentCapabilities = [
        .streaming,
        .reasoning,
        .toolCalls,
        .sessions,
        .resume,
        .mcp,
        .usage,
        .fileChanges,
        .shellCommands,
    ]
    nonisolated let events: AsyncStream<AgentEvent>
    nonisolated let sessionEvents: AsyncStream<AgentBackendEvent>

    private let executableResolver: ExecutableResolver
    private let installationProbe: InstallationProbe
    private let environmentProvider: EnvironmentProvider
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let sessionEventContinuation: AsyncStream<AgentBackendEvent>.Continuation
    private var runtimes: [String: Runtime] = [:]

    init(
        executableResolver: @escaping ExecutableResolver = {
            let environment = HermesFileService.enrichedEnvironment()
            return ClaudeExecutableResolver.resolve(environment: environment)
        },
        installationProbe: @escaping InstallationProbe = ClaudeCodeBackend.defaultInstallationProbe,
        environmentProvider: @escaping EnvironmentProvider = {
            HermesFileService.enrichedEnvironment()
        }
    ) {
        self.executableResolver = executableResolver
        self.installationProbe = installationProbe
        self.environmentProvider = environmentProvider

        var continuation: AsyncStream<AgentEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation

        var sessionContinuation: AsyncStream<AgentBackendEvent>.Continuation!
        self.sessionEvents = AsyncStream { sessionContinuation = $0 }
        self.sessionEventContinuation = sessionContinuation
    }

    nonisolated func installationStatus() async -> AgentInstallationStatus {
        guard let executable = executableResolver() else { return .notInstalled }
        return await installationProbe(executable)
    }

    nonisolated func models() async throws -> [AgentModel] {
        // Claude model aliases evolve independently of Scarf. Model discovery
        // will move to the control initialize response rather than hard-coding
        // a list that can go stale.
        []
    }

    func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
        guard let executable = executableResolver() else {
            throw AgentError(
                code: "claude.not-installed",
                message: "Claude Code executable could not be found"
            )
        }

        let sessionID = UUID().uuidString.lowercased()
        let workingDirectory = configuration.workingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let session = AgentSession(
            id: sessionID,
            backendID: .claudeCode,
            workingDirectory: workingDirectory,
            metadata: configuration.metadata
        )

        try await startRuntime(
            for: session,
            executable: executable,
            modelID: configuration.modelID,
            resume: false
        )
        return session
    }

    func resumeSession(_ session: AgentSession) async throws -> AgentSession {
        guard session.backendID == .claudeCode else {
            throw AgentError(
                code: "claude.invalid-backend",
                message: "Session does not belong to Claude Code"
            )
        }
        if runtimes[session.id] != nil { return session }
        guard let executable = executableResolver() else {
            throw AgentError(
                code: "claude.not-installed",
                message: "Claude Code executable could not be found"
            )
        }

        try await startRuntime(
            for: session,
            executable: executable,
            modelID: session.metadata["model"],
            resume: true
        )
        return session
    }

    func send(_ message: AgentMessage, in session: AgentSession) async throws {
        guard message.role == .user else {
            throw AgentError(
                code: "claude.unsupported-message-role",
                message: "Claude Code backend accepts user messages through the generic send interface"
            )
        }
        guard let runtime = runtimes[session.id] else {
            throw AgentError(
                code: "claude.session-not-active",
                message: "Claude Code session is not active"
            )
        }
        try await runtime.manager.sendUserMessage(message.content)
    }

    func respond(
        to request: AgentPermissionRequest,
        optionID: String,
        in session: AgentSession
    ) async throws {
        throw AgentError(
            code: "claude.permissions-not-implemented",
            message: "Claude Code host permission responses are not enabled yet"
        )
    }

    func cancelPermission(
        _ request: AgentPermissionRequest,
        in session: AgentSession
    ) async throws {
        throw AgentError(
            code: "claude.permissions-not-implemented",
            message: "Claude Code host permission responses are not enabled yet"
        )
    }

    func cancel(session: AgentSession) async {
        guard let runtime = runtimes[session.id] else { return }
        do {
            _ = try await runtime.manager.sendInterrupt()
        } catch {
            yield(.error(AgentError(
                code: "claude.interrupt-failed",
                message: error.localizedDescription,
                isRecoverable: true
            )), sessionID: session.id)
        }
    }

    func close(session: AgentSession) async {
        guard let runtime = runtimes.removeValue(forKey: session.id) else { return }
        runtime.incomingTask.cancel()
        runtime.stderrTask.cancel()
        await runtime.manager.close()
        yield(.sessionClosed, sessionID: session.id)
    }

    private func startRuntime(
        for session: AgentSession,
        executable: String,
        modelID: String?,
        resume: Bool
    ) async throws {
        if let existing = runtimes.removeValue(forKey: session.id) {
            existing.incomingTask.cancel()
            existing.stderrTask.cancel()
            await existing.manager.close()
        }

        let workingDirectory = session.workingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let launch = ClaudeLaunchConfiguration(
            executable: executable,
            workingDirectory: workingDirectory,
            sessionID: session.id,
            modelID: modelID,
            resume: resume
        )
        let command = ClaudeProcessConfiguration.command(for: launch)
        let manager = ClaudeProcessManager(environmentProvider: environmentProvider)
        let decoder = ClaudeStreamDecoder()
        let streams = try await manager.start(command: command)

        let incomingTask = Task { [weak self, decoder] in
            guard let self else { return }
            await self.consumeIncoming(streams.incoming, decoder: decoder, sessionID: session.id)
        }
        let stderrTask = Task { [weak self] in
            guard let self else { return }
            await self.drainStderr(streams.stderr, sessionID: session.id)
        }

        runtimes[session.id] = Runtime(
            manager: manager,
            decoder: decoder,
            incomingTask: incomingTask,
            stderrTask: stderrTask
        )
    }

    private func consumeIncoming(
        _ stream: AsyncThrowingStream<String, Error>,
        decoder: ClaudeStreamDecoder,
        sessionID: String
    ) async {
        do {
            for try await line in stream {
                guard !Task.isCancelled else { return }

                do {
                    if let control = try ClaudeControlProtocol.decodeResponse(line) {
                        if !control.isSuccess {
                            yield(.error(AgentError(
                                code: "claude.control-response-error",
                                message: control.errorMessage ?? "Claude Code rejected a control request",
                                isRecoverable: true
                            )), sessionID: sessionID)
                        }
                        continue
                    }

                    let mapped = try await decoder.decode(line: line)
                    for event in mapped {
                        yield(event, sessionID: sessionID)
                    }
                } catch let error as ClaudeStreamDecoderError {
                    yield(.error(AgentError(
                        code: "claude.invalid-stream-json",
                        message: "Claude Code emitted a malformed stream-json frame: \(error)",
                        isRecoverable: true
                    )), sessionID: sessionID)
                } catch let error as ClaudeControlProtocolError {
                    yield(.error(AgentError(
                        code: "claude.invalid-control-json",
                        message: "Claude Code emitted a malformed control frame: \(error)",
                        isRecoverable: true
                    )), sessionID: sessionID)
                } catch {
                    yield(.error(AgentError(
                        code: "claude.stream-decode-failed",
                        message: error.localizedDescription,
                        isRecoverable: true
                    )), sessionID: sessionID)
                }
            }

            if !Task.isCancelled, runtimes[sessionID] != nil {
                yield(.error(AgentError(
                    code: "claude.process-ended",
                    message: "Claude Code process ended unexpectedly",
                    isRecoverable: true
                )), sessionID: sessionID)
            }
        } catch {
            if !Task.isCancelled, runtimes[sessionID] != nil {
                yield(.error(AgentError(
                    code: "claude.process-stream-failed",
                    message: error.localizedDescription,
                    isRecoverable: true
                )), sessionID: sessionID)
            }
        }
    }

    private func drainStderr(
        _ stream: AsyncThrowingStream<String, Error>,
        sessionID: String
    ) async {
        do {
            for try await _ in stream {
                if Task.isCancelled { return }
                // stderr is drained to prevent pipe backpressure. Normal Claude
                // diagnostics are not promoted to user-visible errors; stdout
                // result/control frames remain the source of truth.
            }
        } catch {
            if !Task.isCancelled, runtimes[sessionID] != nil {
                yield(.error(AgentError(
                    code: "claude.stderr-stream-failed",
                    message: error.localizedDescription,
                    isRecoverable: true
                )), sessionID: sessionID)
            }
        }
    }

    private func yield(_ event: AgentEvent, sessionID: String) {
        eventContinuation.yield(event)
        sessionEventContinuation.yield(AgentBackendEvent(sessionID: sessionID, event: event))
    }

    nonisolated private static func defaultInstallationProbe(
        executable: String
    ) async -> AgentInstallationStatus {
        do {
            let result = try await LocalTransport().asyncRunProcess(
                executable: executable,
                args: ["--version"],
                stdin: nil,
                timeout: 10
            )
            guard result.exitCode == 0 else {
                let reason = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                return .unavailable(
                    reason: reason.isEmpty ? "Claude Code exited with status \(result.exitCode)" : reason
                )
            }
            let version = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .available(version: version.isEmpty ? nil : version)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }
}
