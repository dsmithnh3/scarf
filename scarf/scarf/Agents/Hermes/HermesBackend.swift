import Foundation
import ScarfCore

/// Multi-agent adapter for Scarf's existing Hermes ACP runtime.
///
/// This type delegates to the production `ACPClient.forMacApp` path instead of
/// replacing it. Existing Hermes-only services (memory, cron, gateway, proxy,
/// configuration, etc.) remain owned by their current implementations.
actor HermesBackend: SessionScopedAgentBackend {
    typealias InstallationProbe = @Sendable () async -> AgentInstallationStatus

    nonisolated let id: AgentID = .hermes
    nonisolated let displayName = "Hermes"
    nonisolated let capabilities: AgentCapabilities = [
        .streaming,
        .reasoning,
        .toolCalls,
        .permissions,
        .sessions,
        .resume,
        .mcp,
        .skills,
        .usage,
        .shellCommands,
        .memory,
        .cron,
        .gateway,
        .proxy,
        .remoteExecution,
    ]
    nonisolated let events: AsyncStream<AgentEvent>
    nonisolated let sessionEvents: AsyncStream<AgentBackendEvent>

    private let context: ServerContext
    private let installationProbe: InstallationProbe
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let sessionEventContinuation: AsyncStream<AgentBackendEvent>.Continuation
    private var clients: [String: ACPClient] = [:]
    private var forwardingTasks: [String: Task<Void, Never>] = [:]

    init(
        context: ServerContext = .local,
        installationProbe: InstallationProbe? = nil
    ) {
        self.context = context

        var continuation: AsyncStream<AgentEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation

        var sessionContinuation: AsyncStream<AgentBackendEvent>.Continuation!
        self.sessionEvents = AsyncStream { sessionContinuation = $0 }
        self.sessionEventContinuation = sessionContinuation

        if let installationProbe {
            self.installationProbe = installationProbe
        } else {
            self.installationProbe = Self.makeInstallationProbe(context: context)
        }
    }

    nonisolated private static func makeInstallationProbe(
        context: ServerContext
    ) -> InstallationProbe {
        {
            do {
                let result = try await context.makeTransport().asyncRunProcess(
                    executable: context.paths.hermesBinary,
                    args: ["--version"],
                    stdin: nil,
                    timeout: 10
                )
                guard result.exitCode == 0 else {
                    let reason = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .unavailable(reason: reason.isEmpty ? "Hermes exited with status \(result.exitCode)" : reason)
                }
                let version = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                return .available(version: version.isEmpty ? nil : version)
            } catch {
                return .unavailable(reason: error.localizedDescription)
            }
        }
    }

    nonisolated func installationStatus() async -> AgentInstallationStatus {
        await installationProbe()
    }

    nonisolated func models() async throws -> [AgentModel] {
        // Hermes's existing model/catalog UI remains authoritative during the
        // first migration phase. The generic catalog can be wired later without
        // changing chat/session behavior.
        []
    }

    func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
        let cwd = configuration.workingDirectory?.path ?? FileManager.default.currentDirectoryPath
        let client = ACPClient.forMacApp(context: context, projectCwd: cwd)
        try await client.start()
        let sessionID = try await client.newSession(cwd: cwd)
        clients[sessionID] = client
        startForwarding(client: client, sessionID: sessionID)

        let session = AgentSession(
            id: sessionID,
            backendID: .hermes,
            workingDirectory: configuration.workingDirectory,
            metadata: configuration.metadata
        )
        yield(.sessionStarted(session), sessionID: sessionID)
        return session
    }

    func resumeSession(_ session: AgentSession) async throws -> AgentSession {
        guard session.backendID == .hermes else {
            throw AgentError(code: "hermes.invalid-backend", message: "Session does not belong to Hermes")
        }
        if clients[session.id] != nil { return session }

        let cwd = session.workingDirectory?.path ?? FileManager.default.currentDirectoryPath
        let client = ACPClient.forMacApp(context: context, projectCwd: cwd)
        try await client.start()
        let loadedID = try await client.loadSession(cwd: cwd, sessionId: session.id)
        clients[loadedID] = client
        startForwarding(client: client, sessionID: loadedID)

        let resumed = AgentSession(
            id: loadedID,
            backendID: .hermes,
            workingDirectory: session.workingDirectory,
            metadata: session.metadata
        )
        yield(.sessionStarted(resumed), sessionID: loadedID)
        return resumed
    }

    /// ACP `session/load` replays history as streaming chunks, not a
    /// structured `[AgentMessage]` payload. Returning `[]` keeps restore
    /// reconcile Scarf-preferring until a verified structured source
    /// (state.db read or replay collector) is wired. Do not advertise a
    /// history capability.
    func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage] {
        []
    }

    func send(_ message: AgentMessage, in session: AgentSession) async throws {
        guard message.role == .user else {
            throw AgentError(
                code: "hermes.unsupported-message-role",
                message: "Hermes backend accepts user messages through the generic send interface"
            )
        }
        guard let client = clients[session.id] else {
            throw AgentError(code: "hermes.session-not-active", message: "Hermes session is not active")
        }

        let response = try await client.sendPrompt(sessionId: session.id, text: message.content)
        for event in HermesEventMapper.map(.promptComplete(sessionId: session.id, response: response)) {
            yield(event, sessionID: session.id)
        }
    }

    func respond(
        to request: AgentPermissionRequest,
        optionID: String,
        in session: AgentSession
    ) async throws {
        guard let requestID = Int(request.id) else {
            throw AgentError(code: "hermes.invalid-permission-id", message: "Hermes permission request id is invalid")
        }
        guard let client = clients[session.id] else {
            throw AgentError(code: "hermes.session-not-active", message: "Hermes session is not active")
        }
        await client.respondToPermission(requestId: requestID, optionId: optionID)
    }

    func cancelPermission(
        _ request: AgentPermissionRequest,
        in session: AgentSession
    ) async throws {
        guard let requestID = Int(request.id) else {
            throw AgentError(code: "hermes.invalid-permission-id", message: "Hermes permission request id is invalid")
        }
        guard let client = clients[session.id] else {
            throw AgentError(code: "hermes.session-not-active", message: "Hermes session is not active")
        }
        await client.cancelPermission(requestId: requestID)
    }

    func cancel(session: AgentSession) async {
        guard let client = clients[session.id] else { return }
        do {
            try await client.cancel(sessionId: session.id)
        } catch {
            yield(.error(AgentError(
                code: "hermes.cancel-failed",
                message: error.localizedDescription,
                isRecoverable: true
            )), sessionID: session.id)
        }
    }

    func close(session: AgentSession) async {
        forwardingTasks.removeValue(forKey: session.id)?.cancel()
        if let client = clients.removeValue(forKey: session.id) {
            await client.stop()
        }
        yield(.sessionClosed, sessionID: session.id)
    }

    private func startForwarding(client: ACPClient, sessionID: String) {
        forwardingTasks.removeValue(forKey: sessionID)?.cancel()
        forwardingTasks[sessionID] = Task { [weak self] in
            for await event in await client.events {
                guard !Task.isCancelled else { break }
                for mapped in HermesEventMapper.map(event) {
                    await self?.yield(mapped, sessionID: sessionID)
                }
            }
        }
    }

    private func yield(_ event: AgentEvent, sessionID: String) {
        eventContinuation.yield(event)
        sessionEventContinuation.yield(AgentBackendEvent(sessionID: sessionID, event: event))
    }
}
