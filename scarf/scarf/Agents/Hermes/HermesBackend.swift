import Foundation
import ScarfCore

/// Multi-agent adapter for Scarf's existing Hermes ACP runtime.
///
/// This type delegates to the production `ACPClient.forMacApp` path instead of
/// replacing it. Existing Hermes-only services (memory, cron, gateway, proxy,
/// configuration, etc.) remain owned by their current implementations.
actor HermesBackend: SessionScopedAgentBackend {
    typealias ExecutableResolver = @Sendable () -> String?
    typealias InstallationProbe = @Sendable () async -> AgentInstallationStatus
    /// Same verdict as chat's credential preflight (`HermesFileService.hasAnyAICredential`).
    typealias CredentialProbe = @Sendable () -> Bool
    typealias ConversationHistoryLoader = @Sendable (ServerContext, String) async throws -> [AgentMessage]
    /// Configured `model.provider` from Hermes config. Nil / empty / `unknown`
    /// means models() returns [].
    typealias ConfiguredProviderResolver = @Sendable () -> String?
    /// models.dev / overlay catalog rows for one provider id.
    typealias CatalogModelsLoader = @Sendable (String) async -> [AgentModel]
    /// Nous Portal rows already mapped into ``AgentModel`` (`nous:<id>`).
    typealias NousModelsLoader = @Sendable () async -> [AgentModel]
    /// Test seam for ACP `session/set_model` without a live client.
    typealias SessionModelApplier = @Sendable (
        _ sessionID: String,
        _ modelID: String,
        _ providerID: String?
    ) async throws -> Void
    /// Test seam for ACP `session/set_mode` without a live client.
    typealias SessionModeApplier = @Sendable (
        _ sessionID: String,
        _ modeID: String
    ) async throws -> Void

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
    private let executableResolver: ExecutableResolver
    private let installationProbe: InstallationProbe
    private let credentialProbe: CredentialProbe
    private let conversationHistoryLoader: ConversationHistoryLoader
    private let configuredProviderResolver: ConfiguredProviderResolver
    private let catalogModelsLoader: CatalogModelsLoader
    private let nousModelsLoader: NousModelsLoader
    private let sessionModelApplier: SessionModelApplier?
    private let sessionModeApplier: SessionModeApplier?
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let sessionEventContinuation: AsyncStream<AgentBackendEvent>.Continuation
    private var clients: [String: ACPClient] = [:]
    private var forwardingTasks: [String: Task<Void, Never>] = [:]

    init(
        context: ServerContext = .local,
        executableResolver: ExecutableResolver? = nil,
        installationProbe: InstallationProbe? = nil,
        credentialProbe: CredentialProbe? = nil,
        conversationHistoryLoader: ConversationHistoryLoader? = nil,
        configuredProviderResolver: ConfiguredProviderResolver? = nil,
        catalogModelsLoader: CatalogModelsLoader? = nil,
        nousModelsLoader: NousModelsLoader? = nil,
        sessionModelApplier: SessionModelApplier? = nil,
        sessionModeApplier: SessionModeApplier? = nil
    ) {
        self.context = context
        self.conversationHistoryLoader = conversationHistoryLoader ?? Self.defaultConversationHistoryLoader

        var continuation: AsyncStream<AgentEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation

        var sessionContinuation: AsyncStream<AgentBackendEvent>.Continuation!
        self.sessionEvents = AsyncStream { sessionContinuation = $0 }
        self.sessionEventContinuation = sessionContinuation

        let resolver = executableResolver ?? Self.makeExecutableResolver(context: context)
        self.executableResolver = resolver

        if let installationProbe {
            self.installationProbe = installationProbe
        } else {
            self.installationProbe = Self.makeInstallationProbe(
                context: context,
                executableResolver: resolver
            )
        }

        // Reuse the verified chat preflight — env / .env / auth.json / config —
        // rather than inventing a second credential detector or OAuth UI.
        self.credentialProbe = credentialProbe ?? {
            HermesFileService(context: context).hasAnyAICredential()
        }

        self.configuredProviderResolver = configuredProviderResolver
            ?? Self.makeConfiguredProviderResolver(context: context)
        self.catalogModelsLoader = catalogModelsLoader
            ?? Self.makeCatalogModelsLoader(context: context)
        self.nousModelsLoader = nousModelsLoader
            ?? Self.makeNousModelsLoader(context: context)
        self.sessionModelApplier = sessionModelApplier
        self.sessionModeApplier = sessionModeApplier
    }

    nonisolated private static func makeExecutableResolver(
        context: ServerContext
    ) -> ExecutableResolver {
        {
            context.paths.hermesBinaryIfInstalled
        }
    }

    nonisolated private static func makeConfiguredProviderResolver(
        context: ServerContext
    ) -> ConfiguredProviderResolver {
        {
            guard let yaml = HermesConfigReader.readRawConfig(context: context) else {
                return nil
            }
            let provider = HermesConfig(yaml: yaml).provider
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !provider.isEmpty, provider.lowercased() != "unknown" else {
                return nil
            }
            return provider
        }
    }

    nonisolated private static func makeCatalogModelsLoader(
        context: ServerContext
    ) -> CatalogModelsLoader {
        { provider in
            ModelCatalogService(context: context)
                .loadModels(for: provider)
                .map { AgentModel(id: $0.id, displayName: $0.modelName) }
        }
    }

    nonisolated private static func makeNousModelsLoader(
        context: ServerContext
    ) -> NousModelsLoader {
        {
            let result = await NousModelCatalogService(context: context)
                .loadModels(forceRefresh: false)
            let models: [NousModel]
            switch result {
            case .fresh(let list, _), .cache(let list, _, _), .fallback(let list, _):
                models = list
            }
            return NousModelCatalogService.agenticModels(models).map {
                AgentModel(id: "nous:\($0.id)", displayName: $0.id)
            }
        }
    }

    nonisolated private static func makeInstallationProbe(
        context: ServerContext,
        executableResolver: @escaping ExecutableResolver
    ) -> InstallationProbe {
        {
            guard let executable = executableResolver() else {
                return .notInstalled
            }
            do {
                let result = try await context.makeTransport().asyncRunProcess(
                    executable: executable,
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

    nonisolated func resolvedExecutablePath() -> String? {
        executableResolver()
    }

    nonisolated func authHealth() async -> AgentAuthHealth {
        credentialProbe() ? .credentialsDetected : .noCredentialsDetected
    }

    nonisolated func models() async throws -> [AgentModel] {
        // Thin bridge over the Rich Chat catalogs for the configured
        // `model.provider` only. Do not invent a parallel list; Claude models
        // stay on control initialize.
        guard let raw = configuredProviderResolver() else { return [] }
        let provider = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, provider.lowercased() != "unknown" else { return [] }

        if provider.lowercased() == "nous" {
            return await nousModelsLoader()
        }
        return await catalogModelsLoader(provider)
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

    /// Structured history from read-only Hermes `state.db` rows (same SQL path
    /// as Rich Chat). ACP `session/load` streaming replay is unchanged. Do not
    /// advertise a history capability until end-to-end restore matching is
    /// product-approved (Hermes row ids ≠ Scarf UUIDs).
    func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage] {
        guard session.backendID == .hermes else {
            throw AgentError(code: "hermes.invalid-backend", message: "Session does not belong to Hermes")
        }
        return try await conversationHistoryLoader(context, session.id)
    }

    /// Live ACP `session/set_model` on an active Hermes session.
    ///
    /// Does not restart the process. Callers must pass provider/model already
    /// split via ``AgentModelPickerID/split(_:)`` — never the raw picker id as
    /// `modelID` alone when a provider prefix is present.
    func setSessionModel(
        session: AgentSession,
        modelID: String,
        providerID: String?
    ) async throws {
        guard session.backendID == .hermes else {
            throw AgentError(code: "hermes.invalid-backend", message: "Session does not belong to Hermes")
        }
        if let sessionModelApplier {
            try await sessionModelApplier(session.id, modelID, providerID)
            return
        }
        guard let client = clients[session.id] else {
            throw AgentError(code: "hermes.session-not-active", message: "Hermes session is not active")
        }
        try await client.setSessionModel(
            sessionId: session.id,
            modelID: modelID,
            providerID: providerID
        )
    }

    /// Live ACP `session/set_mode` on an active Hermes session (v0.15+).
    func setSessionMode(
        session: AgentSession,
        modeID: String
    ) async throws {
        guard session.backendID == .hermes else {
            throw AgentError(code: "hermes.invalid-backend", message: "Session does not belong to Hermes")
        }
        if let sessionModeApplier {
            try await sessionModeApplier(session.id, modeID)
            return
        }
        guard let client = clients[session.id] else {
            throw AgentError(code: "hermes.session-not-active", message: "Hermes session is not active")
        }
        try await client.setSessionMode(sessionId: session.id, modeId: modeID)
    }

    nonisolated private static func defaultConversationHistoryLoader(
        context: ServerContext,
        sessionID: String
    ) async throws -> [AgentMessage] {
        try await HermesAgentConversationHistory.fetchMessages(sessionID: sessionID, context: context)
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
        guard message.role == .user else {
            throw AgentError(
                code: "hermes.unsupported-message-role",
                message: "Hermes backend accepts user messages through the generic send interface"
            )
        }
        guard let client = clients[session.id] else {
            throw AgentError(code: "hermes.session-not-active", message: "Hermes session is not active")
        }

        let response = try await client.sendPrompt(
            sessionId: session.id,
            text: message.content,
            images: images,
            contextNotes: contextNotes
        )
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
