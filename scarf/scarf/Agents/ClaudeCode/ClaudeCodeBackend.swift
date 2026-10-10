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
    typealias AuthStatusProbe = @Sendable (_ executable: String, _ environment: [String: String]) async -> AgentAuthHealth
    typealias ChannelFactory = @Sendable (
        _ command: ClaudeProcessCommand,
        _ environment: [String: String]
    ) async throws -> any ACPChannel

    private struct Runtime {
        let manager: ClaudeProcessManager
        let decoder: ClaudeStreamDecoder
        let incomingTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>
        var initializeRequestID: String?
    }

    private struct PendingPermission: Sendable {
        let sessionID: String
        let inputJSON: String
    }

    nonisolated let id: AgentID = .claudeCode
    nonisolated let displayName = "Claude Code"
    /// `.permissions` is advertised only with host-prompting launch
    /// (`--permission-mode default` + `--permission-prompt-tool stdio`) and
    /// a verified can_use_tool receive/answer round trip.
    nonisolated let capabilities: AgentCapabilities = [
        .streaming,
        .reasoning,
        .toolCalls,
        .permissions,
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
    private let authStatusProbe: AuthStatusProbe
    private let channelFactory: ChannelFactory?
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let sessionEventContinuation: AsyncStream<AgentBackendEvent>.Continuation
    private var runtimes: [String: Runtime] = [:]
    private var pendingPermissions: [String: PendingPermission] = [:]
    /// Last initialize `models` list. Empty until a fixture-shaped success payload arrives.
    private var discoveredModels: [AgentModel] = []
    /// Last initialize `agents` mapped to Claude skill descriptors. Empty until
    /// a fixture-shaped success payload arrives. Static catalog stub stays [].
    private var discoveredSkillExtensions: [AgentExtensionDescriptor] = []

    init(
        executableResolver: @escaping ExecutableResolver = {
            let environment = HermesFileService.enrichedEnvironment()
            return ClaudeExecutableResolver.resolve(environment: environment)
        },
        installationProbe: @escaping InstallationProbe = ClaudeCodeBackend.defaultInstallationProbe,
        environmentProvider: @escaping EnvironmentProvider = {
            HermesFileService.enrichedEnvironment()
        },
        authStatusProbe: @escaping AuthStatusProbe = ClaudeAuthStatusProbe.run,
        channelFactory: ChannelFactory? = nil
    ) {
        self.executableResolver = executableResolver
        self.installationProbe = installationProbe
        self.environmentProvider = environmentProvider
        self.authStatusProbe = authStatusProbe
        self.channelFactory = channelFactory

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

    nonisolated func resolvedExecutablePath() -> String? {
        executableResolver()
    }

    nonisolated func authHealth() async -> AgentAuthHealth {
        guard let executable = executableResolver() else { return .notProbed }
        let environment = ClaudeProcessEnvironment.sanitized(environmentProvider())
        return await authStatusProbe(executable, environment)
    }

    nonisolated func models() async throws -> [AgentModel] {
        await discoveredModels
    }

    nonisolated func discoveredExtensions() async -> [AgentExtensionDescriptor] {
        await discoveredSkillExtensions
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

    /// Claude `--resume` restarts the process; Scarf has no verified
    /// structured transcript/history API yet (re-probed 2026-10-08 against
    /// CLI 2.1.289 — see `documents/research/2026-10-08-claude-structured-history-probe.md`).
    ///
    /// Returning `[]` is intentional: restore then prefers Scarf's durable
    /// transcript via ``AgentConversationTranscript/reconciling(withBackendHistory:)``.
    /// Do not scrape Claude JSONL, invent a parser, or advertise a history
    /// capability until a version-pinned SDK/API returns structured messages.
    func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage] {
        _ = session
        return []
    }

    func send(_ message: AgentMessage, in session: AgentSession) async throws {
        try await send(message, images: [], contextNotes: [], in: session)
    }

    func send(
        _ message: AgentMessage,
        images: [ChatImageAttachment],
        contextNotes: [ACPContextNote],
        in session: AgentSession
    ) async throws {
        if !images.isEmpty {
            throw AgentError(
                code: "claude.images-unsupported",
                message: "Claude Code in Scarf does not support image attachments yet. Send text only, or use a Hermes project for vision prompts.",
                isRecoverable: true
            )
        }
        if !contextNotes.isEmpty {
            throw AgentError(
                code: "claude.context-notes-unsupported",
                message: "Claude Code does not support Live Voice context notes",
                isRecoverable: true
            )
        }
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
        guard let runtime = runtimes[session.id] else {
            throw AgentError(
                code: "claude.session-not-active",
                message: "Claude Code session is not active"
            )
        }

        let decision: ClaudePermissionDecision
        switch optionID {
        case "allow":
            // Echo the original tool input when we still have it; Claude accepts
            // allow without `updatedInput` as well.
            decision = .allow(updatedInputJSON: pendingPermissions[request.id]?.inputJSON)
        case "deny":
            decision = .deny(message: "Denied by user")
        default:
            throw AgentError(
                code: "claude.invalid-permission-option",
                message: "Claude Code permission option must be allow or deny"
            )
        }

        let line = try ClaudeControlProtocol.encodePermissionResponse(
            requestID: request.id,
            decision: decision
        )
        try await runtime.manager.sendRecord(line)
        pendingPermissions.removeValue(forKey: request.id)
    }

    func cancelPermission(
        _ request: AgentPermissionRequest,
        in session: AgentSession
    ) async throws {
        guard let runtime = runtimes[session.id] else {
            throw AgentError(
                code: "claude.session-not-active",
                message: "Claude Code session is not active"
            )
        }

        // Claude's verified can_use_tool wire only defines allow/deny behaviors;
        // host cancel maps to deny so the process is not left waiting.
        let line = try ClaudeControlProtocol.encodePermissionResponse(
            requestID: request.id,
            decision: .deny(message: "Cancelled by user")
        )
        try await runtime.manager.sendRecord(line)
        pendingPermissions.removeValue(forKey: request.id)
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
        pendingPermissions = pendingPermissions.filter { $0.value.sessionID != session.id }
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
            pendingPermissions = pendingPermissions.filter { $0.value.sessionID != session.id }
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
        let baseEnvironment = environmentProvider
        let sanitizedEnvironment: EnvironmentProvider = {
            ClaudeProcessEnvironment.sanitized(baseEnvironment())
        }
        let manager: ClaudeProcessManager
        if let channelFactory {
            manager = ClaudeProcessManager(
                channelFactory: channelFactory,
                environmentProvider: sanitizedEnvironment
            )
        } else {
            manager = ClaudeProcessManager(environmentProvider: sanitizedEnvironment)
        }
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

        let initializeRequestID = ClaudeControlProtocol.makeRequestID()
        runtimes[session.id] = Runtime(
            manager: manager,
            decoder: decoder,
            incomingTask: incomingTask,
            stderrTask: stderrTask,
            initializeRequestID: initializeRequestID
        )
        do {
            try await manager.sendRecord(
                ClaudeControlProtocol.encodeInitialize(requestID: initializeRequestID)
            )
        } catch {
            runtimes[session.id] = nil
            incomingTask.cancel()
            stderrTask.cancel()
            await manager.close()
            throw error
        }
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
                        let isInitialize = control.isSuccess
                            && control.requestID == runtimes[sessionID]?.initializeRequestID
                        if isInitialize, let result = try ClaudeControlProtocol.decodeInitializeResult(line) {
                            let models = result.models.map {
                                AgentModel(id: $0.value, displayName: $0.displayName)
                            }
                            let commands = AgentSlashCommandCatalogs.claudeCodeCommands(
                                from: result.commands.map {
                                    AgentSlashCommandCatalogs.ClaudeDiscoveredCommand(
                                        name: $0.name,
                                        description: $0.description,
                                        argumentHint: $0.argumentHint,
                                        aliases: $0.aliases
                                    )
                                }
                            )
                            discoveredModels = models
                            discoveredSkillExtensions = Self.skillDescriptors(from: result.agents)
                            yield(.availableCommandsUpdated(commands), sessionID: sessionID)
                        } else if !control.isSuccess {
                            yield(.error(AgentError(
                                code: "claude.control-response-error",
                                message: control.errorMessage ?? "Claude Code rejected a control request",
                                isRecoverable: true
                            )), sessionID: sessionID)
                        }
                        continue
                    }

                    if let permission = try ClaudeControlProtocol.decodePermissionRequest(line) {
                        pendingPermissions[permission.requestID] = PendingPermission(
                            sessionID: sessionID,
                            inputJSON: permission.inputJSON
                        )
                        yield(
                            .permissionRequested(Self.permissionRequest(from: permission)),
                            sessionID: sessionID
                        )
                        continue
                    }

                    let mapped = try await decoder.decode(line: line)
                    for event in mapped {
                        yield(
                            Self.alignedEvent(event, runtimeSessionID: sessionID),
                            sessionID: sessionID
                        )
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

    /// Normalize a decoded Claude `can_use_tool` control request into the
    /// generic permission event shape used by the conversation coordinator.
    nonisolated static func permissionRequest(
        from permission: ClaudePermissionControlRequest
    ) -> AgentPermissionRequest {
        AgentPermissionRequest(
            id: permission.requestID,
            title: permission.toolName,
            detail: "can_use_tool",
            options: [
                AgentPermissionOption(id: "allow", title: "Allow"),
                AgentPermissionOption(id: "deny", title: "Deny"),
            ]
        )
    }

    /// Keep Scarf's runtime session id as the routing key even when Claude's
    /// system init reports a different `session_id`. Divergent ids are retained
    /// in metadata for diagnostics without orphaning later scoped events.
    nonisolated private static func alignedEvent(
        _ event: AgentEvent,
        runtimeSessionID: String
    ) -> AgentEvent {
        guard case .sessionStarted(let reported) = event else { return event }
        guard reported.id != runtimeSessionID else { return event }

        var metadata = reported.metadata
        metadata["claudeReportedSessionID"] = reported.id
        return .sessionStarted(AgentSession(
            id: runtimeSessionID,
            backendID: reported.backendID,
            workingDirectory: reported.workingDirectory,
            metadata: metadata
        ))
    }

    /// Map initialize agents (CLI 2.1.289: name / description / model) into
    /// Claude skill catalog rows. Does not scrape disk; empty input → [].
    nonisolated static func skillDescriptors(
        from agents: [ClaudeInitializeAgent]
    ) -> [AgentExtensionDescriptor] {
        agents.map { agent in
            var description = agent.description
            if let model = agent.model, !model.isEmpty {
                let suffix = "model: \(model)"
                description = description.isEmpty ? suffix : "\(description) (\(suffix))"
            }
            return AgentExtensionDescriptor(
                name: agent.name,
                description: description,
                kind: .claudeCodeSkill,
                source: .claudeCode,
                backendScope: .backends([.claudeCode]),
                availability: .available
            )
        }
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
