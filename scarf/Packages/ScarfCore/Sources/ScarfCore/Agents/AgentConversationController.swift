import Foundation

public enum AgentConversationControllerError: Error, Equatable, Sendable {
    case noActiveSession
}

/// Owns one backend-neutral conversation lifecycle on top of `AgentCoordinator`.
///
/// The controller intentionally contains no SwiftUI/AppKit dependencies. It
/// creates/resumes a selected backend session, sends user turns, routes control
/// actions, and reduces backend events into `AgentConversationState`.
public actor AgentConversationController {
    /// State snapshots emitted after every controller-owned mutation.
    ///
    /// This is the observation seam for app-facing view models. Consumers react
    /// to the state they actually need instead of trying to infer when multiple
    /// asynchronous backend/coordinator queues have drained.
    public nonisolated let stateUpdates: AsyncStream<AgentConversationState>

    /// Stable Scarf-owned key for this conversation (window/tab). When set with
    /// an ``identityStore``, successful start/resume writes backend+session id
    /// so a relaunch can restore without inventing a second state system.
    public nonisolated let conversationID: String?

    private let coordinator: AgentCoordinator
    private let identityStore: (any AgentConversationIdentityPersisting)?
    private let transcriptStore: (any AgentConversationTranscriptPersisting)?
    private let stateContinuation: AsyncStream<AgentConversationState>.Continuation
    private var state = AgentConversationState()
    private var activeSession: AgentSession?
    private var activeBackendID: AgentID?
    private var eventTask: Task<Void, Never>?
    private var lastConsumedSequence: UInt64 = 0
    private var routedSequenceWaiters: [(UInt64, CheckedContinuation<Void, Never>)] = []

    public init(
        coordinator: AgentCoordinator,
        conversationID: String? = nil,
        identityStore: (any AgentConversationIdentityPersisting)? = nil,
        transcriptStore: (any AgentConversationTranscriptPersisting)? = nil
    ) {
        self.coordinator = coordinator
        self.conversationID = conversationID
        self.identityStore = identityStore
        self.transcriptStore = transcriptStore

        var continuation: AsyncStream<AgentConversationState>.Continuation!
        self.stateUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            continuation = $0
        }
        self.stateContinuation = continuation
        continuation.yield(state)
    }

    /// App/bootstrap construction: persists identity + durable transcript at
    /// the Hermes-home production paths
    /// (`HermesPathSet.agentConversationIdentities` /
    /// `agentConversationTranscripts`).
    public static func makePersisting(
        coordinator: AgentCoordinator,
        conversationID: String,
        hermesHome: String
    ) -> AgentConversationController {
        AgentConversationController(
            coordinator: coordinator,
            conversationID: conversationID,
            identityStore: AgentConversationIdentityStore(hermesHome: hermesHome),
            transcriptStore: AgentConversationTranscriptStore(hermesHome: hermesHome)
        )
    }

    deinit {
        eventTask?.cancel()
        stateContinuation.finish()
    }

    @discardableResult
    public func startSession(
        backendID: AgentID,
        configuration: AgentSessionConfiguration
    ) async throws -> AgentSession {
        await ensureEventLoop()
        // Release the outgoing session before the replacement exists. A failed
        // close leaves that session active and does not create another one, so
        // the controller never claims both sessions or a session it could not
        // release. A successful close drops the outgoing session before
        // creation; if creation then fails, the controller claims neither.
        try await retireActiveSessionForReplacement()
        let session: AgentSession
        do {
            session = try await coordinator.createSession(
                backendID: backendID,
                configuration: configuration
            )
        } catch {
            // Launch/create failures use the same conversation error slot as
            // stream/process failures so UI has one recovery path.
            surfaceConversationError(
                code: "conversation.start-failed",
                underlying: error
            )
            throw error
        }
        activeBackendID = backendID
        activeSession = session
        state = AgentConversationState()
        state.apply(.sessionStarted(session))
        // A deliberate new start replaces any prior transcript for this
        // conversation id; resume/restore rehydrates instead.
        clearPersistedTranscript()
        persistActiveIdentity(session)
        publishState()
        return session
    }

    @discardableResult
    public func resumeSession(_ session: AgentSession) async throws -> AgentSession {
        await ensureEventLoop()
        let resumed: AgentSession
        do {
            resumed = try await coordinator.resumeSession(session)
        } catch {
            surfaceConversationError(
                code: "conversation.resume-failed",
                underlying: error
            )
            throw error
        }
        // Close only after resume returns the effective identity. Backends may
        // keep the requested id or mint a new one; the active session is
        // released only when that identity actually changes. A failed close
        // leaves the previous session active and drops the resumed session
        // instead of claiming both.
        if let previous = activeSession, !sameSession(previous, resumed) {
            do {
                try await retireActiveSessionForReplacement()
            } catch {
                try? await coordinator.close(session: resumed)
                surfaceConversationError(
                    code: "conversation.resume-failed",
                    underlying: error
                )
                throw error
            }
        }
        activeBackendID = resumed.backendID
        activeSession = resumed
        state = AgentConversationState()
        state.apply(.sessionStarted(resumed))
        persistActiveIdentity(resumed)
        publishState()
        return resumed
    }

    /// Reloads the persisted backend/session identity for this conversation
    /// and resumes it. Returns `nil` when no identity is stored.
    ///
    /// After resume, rehydrates any durable transcript snapshot so a relaunch
    /// restores messages/toolResults/usage without a second state system.
    ///
    /// When `backendHistory` is `nil` (the production default), history is
    /// fetched from the resumed session's backend via
    /// ``AgentCoordinator/fetchConversationHistory(for:)``. Pass an explicit
    /// array to override (tests). Empty history — fetched or supplied —
    /// prefers Scarf via
    /// ``AgentConversationTranscript/reconciling(withBackendHistory:)``.
    @discardableResult
    public func restorePersistedSession(
        backendHistory: [AgentMessage]? = nil
    ) async throws -> AgentSession? {
        guard let conversationID,
              let identityStore,
              let identity = try identityStore.load(conversationID: conversationID) else {
            return nil
        }
        let session = try await resumeSession(identity.makeSession())
        let history: [AgentMessage]
        if let backendHistory {
            history = backendHistory
        } else {
            history = try await coordinator.fetchConversationHistory(for: session)
        }
        hydratePersistedTranscript(backendHistory: history)
        return session
    }

    /// Prefer restoring a stored identity; otherwise create a fresh session.
    ///
    /// This is the production start seam for app view models so persistence
    /// logic stays on the controller rather than spreading through UI.
    ///
    /// `fallbackSessionIDs` bridges Hermes ChatView attributions when Scarf
    /// conversation identity is empty: try each id via ``resumeSession`` +
    /// history hydrate before minting a new session. Failed resumes are
    /// skipped (not fatal).
    @discardableResult
    public func startOrRestorePersistedSession(
        backendID: AgentID,
        configuration: AgentSessionConfiguration,
        fallbackSessionIDs: [String] = []
    ) async throws -> AgentSession {
        if let restored = try await restorePersistedSession() {
            return restored
        }
        for sessionID in fallbackSessionIDs {
            let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let candidate = AgentSession(
                id: trimmed,
                backendID: backendID,
                workingDirectory: configuration.workingDirectory,
                metadata: configuration.modelID.map { ["model": $0] } ?? [:]
            )
            do {
                let resumed = try await resumeSession(candidate)
                let history = try await coordinator.fetchConversationHistory(for: resumed)
                hydratePersistedTranscript(backendHistory: history)
                return resumed
            } catch {
                continue
            }
        }
        return try await startSession(backendID: backendID, configuration: configuration)
    }

    public func send(_ content: String) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }

        let message = AgentMessage(role: .user, content: content)
        state.beginUserTurn(content)
        publishState()
        persistDurableTranscript()

        do {
            try await coordinator.send(message, in: session)
        } catch {
            state.apply(
                .error(
                    AgentError(
                        code: "conversation.send-failed",
                        message: String(describing: error),
                        isRecoverable: true
                    )
                )
            )
            state.apply(.turnCompleted(stopReason: "send_error"))
            publishState()
            persistDurableTranscript()
            throw error
        }
    }

    public func respond(to request: AgentPermissionRequest, optionID: String) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        // Prefer the coordinator's Hermes-preserving wire shape when pending so
        // ACP numeric ids / options stay intact through the backend call.
        let wire = permissionWireRequest(for: request)
        try await coordinator.respond(to: wire, optionID: optionID, in: session)
        _ = state.answerPermission(id: wire.id, optionID: optionID)
        publishState()
    }

    public func cancelPermission(_ request: AgentPermissionRequest) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        let wire = permissionWireRequest(for: request)
        try await coordinator.cancelPermission(wire, in: session)
        _ = state.cancelPermission(id: wire.id)
        publishState()
    }

    public func cancel() async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        try await coordinator.cancel(session: session)
    }

    /// Live mid-session model switch for backends that support it (Hermes ACP
    /// `session/set_model`). Failures surface on ``AgentConversationState/error``
    /// and rethrow so callers can revert optimistic UI.
    public func setSessionModel(modelID: String, providerID: String?) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        do {
            try await coordinator.setSessionModel(
                session: session,
                modelID: modelID,
                providerID: providerID
            )
        } catch {
            surfaceConversationError(
                code: "conversation.set-model-failed",
                underlying: error
            )
            throw error
        }
    }

    /// Live mid-session approval-mode switch (Hermes ACP `session/set_mode`).
    /// Failures surface on ``AgentConversationState/error`` and rethrow.
    public func setSessionMode(modeID: String) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        do {
            try await coordinator.setSessionMode(session: session, modeID: modeID)
        } catch {
            surfaceConversationError(
                code: "conversation.set-mode-failed",
                underlying: error
            )
            throw error
        }
    }

    /// Active session id when a conversation is open.
    public func activeSessionID() -> String? {
        activeSession?.id
    }

    public func close() async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        try await coordinator.close(session: session)
        activeSession = nil
        activeBackendID = nil
        clearPersistedIdentity()
        clearPersistedTranscript()
        state.apply(.sessionClosed)
        publishState()
    }

    public func stateSnapshot() -> AgentConversationState {
        state
    }

    /// Waits until this controller has handled every routed event up through
    /// `sequence`. Ignored events still count, so a caller can prove that an
    /// event was dropped instead of racing the stream.
    func waitUntilRoutedSequenceConsumed(_ sequence: UInt64) async {
        if lastConsumedSequence >= sequence { return }
        await withCheckedContinuation { continuation in
            routedSequenceWaiters.append((sequence, continuation))
        }
    }

    private func sameSession(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        lhs.backendID == rhs.backendID && lhs.id == rhs.id
    }

    /// Wire request for respond/cancel: coordinator record when pending, else
    /// the caller-supplied request (Hermes ACP ids preserved as strings).
    private func permissionWireRequest(for request: AgentPermissionRequest) -> AgentPermissionRequest {
        if let record = state.permissionCoordinator.pending.first(where: { $0.id == request.id }) {
            return record.asAgentPermissionRequest
        }
        return request
    }

    /// Closes the active session so a replacement can take its place.
    ///
    /// The outgoing session stays active when close fails. After a successful
    /// close, both the session and backend pointers are cleared before the
    /// caller installs a replacement. In-flight events for the retired session
    /// therefore cannot be applied to the next session, and a creation failure
    /// cannot leave the controller pointing at a session it already closed.
    private func retireActiveSessionForReplacement() async throws {
        guard let previous = activeSession else { return }
        try await coordinator.close(session: previous)
        guard let current = activeSession,
              current.backendID == previous.backendID,
              current.id == previous.id else {
            return
        }
        activeSession = nil
        activeBackendID = nil
        if !state.isClosed {
            state.apply(.sessionClosed)
            publishState()
        }
    }

    private func ensureEventLoop() async {
        guard eventTask == nil else { return }
        let stream = await coordinator.subscribeToRoutedEvents()
        eventTask = Task { [weak self] in
            for await routed in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(routed)
            }
        }
    }

    private func consume(_ routed: AgentRoutedEvent) {
        lastConsumedSequence = routed.sequence
        resumeRoutedSequenceWaiters()

        // A closed conversation has no active session. Drop both scoped and
        // legacy unscoped events so a late sessionStarted cannot resurrect it.
        guard let session = activeSession, routed.backendID == activeBackendID else { return }

        // Scoped backends can host multiple sessions simultaneously. Ignore an
        // event carrying a different session id; unscoped legacy backends retain
        // their previous backend-only routing behavior while a session is active.
        if let routedSessionID = routed.sessionID {
            guard routedSessionID == session.id else { return }
        }

        state.apply(routed.event)

        if case .sessionStarted(let session) = routed.event {
            activeSession = session
        }

        publishState()
        persistDurableTranscript()
    }

    private func publishState() {
        stateContinuation.yield(state)
    }

    private func surfaceConversationError(code: String, underlying: Error) {
        let message: String
        if let agentError = underlying as? AgentError {
            message = agentError.message
        } else {
            message = String(describing: underlying)
        }
        state.apply(
            .error(
                AgentError(
                    code: code,
                    message: message,
                    isRecoverable: true
                )
            )
        )
        publishState()
    }

    private func persistActiveIdentity(_ session: AgentSession) {
        guard let conversationID, let identityStore else { return }
        do {
            try identityStore.save(
                AgentConversationIdentity(conversationID: conversationID, session: session)
            )
        } catch {
            surfaceConversationError(
                code: "conversation.identity-persist-failed",
                underlying: error
            )
        }
    }

    private func clearPersistedIdentity() {
        guard let conversationID, let identityStore else { return }
        do {
            try identityStore.remove(conversationID: conversationID)
        } catch {
            surfaceConversationError(
                code: "conversation.identity-clear-failed",
                underlying: error
            )
        }
    }

    private func persistDurableTranscript() {
        guard let conversationID, let transcriptStore else { return }
        // Skip empty snapshots so a fresh start does not leave a useless row
        // before the first user turn. Close still clears explicitly.
        let snapshot = AgentConversationTranscript(conversationID: conversationID, state: state)
        guard snapshot.hasDurableContent else { return }
        do {
            try transcriptStore.save(snapshot)
        } catch {
            surfaceConversationError(
                code: "conversation.transcript-persist-failed",
                underlying: error
            )
        }
    }

    private func hydratePersistedTranscript(backendHistory: [AgentMessage] = []) {
        // Attribution-fallback resume (no Scarf identity/transcript yet) still
        // needs Hermes history on the conversation — apply backend rows alone.
        guard let conversationID, let transcriptStore else {
            guard !backendHistory.isEmpty else { return }
            let transcript = AgentConversationTranscript(
                conversationID: "ephemeral"
            ).reconciling(withBackendHistory: backendHistory)
            guard transcript.hasDurableContent else { return }
            state.restoreDurableTranscript(
                messages: transcript.messages,
                toolResults: transcript.toolResults,
                usage: transcript.usage,
                toolCalls: transcript.toolCalls,
                commands: transcript.commands,
                commandOutput: transcript.commandOutput,
                commandResults: transcript.commandResults,
                fileChanges: transcript.fileChanges,
                reasoningBlocks: transcript.reasoningBlocks
            )
            publishState()
            return
        }
        do {
            let loaded = try transcriptStore.load(conversationID: conversationID)
                ?? AgentConversationTranscript(conversationID: conversationID)
            let transcript = loaded.reconciling(withBackendHistory: backendHistory)
            guard transcript.hasDurableContent else { return }
            state.restoreDurableTranscript(
                messages: transcript.messages,
                toolResults: transcript.toolResults,
                usage: transcript.usage,
                toolCalls: transcript.toolCalls,
                commands: transcript.commands,
                commandOutput: transcript.commandOutput,
                commandResults: transcript.commandResults,
                fileChanges: transcript.fileChanges,
                reasoningBlocks: transcript.reasoningBlocks
            )
            publishState()
        } catch {
            surfaceConversationError(
                code: "conversation.transcript-restore-failed",
                underlying: error
            )
        }
    }

    private func clearPersistedTranscript() {
        guard let conversationID, let transcriptStore else { return }
        do {
            try transcriptStore.remove(conversationID: conversationID)
        } catch {
            surfaceConversationError(
                code: "conversation.transcript-clear-failed",
                underlying: error
            )
        }
    }

    private func resumeRoutedSequenceWaiters() {
        var pending: [(UInt64, CheckedContinuation<Void, Never>)] = []
        for (sequence, continuation) in routedSequenceWaiters {
            if lastConsumedSequence >= sequence {
                continuation.resume()
            } else {
                pending.append((sequence, continuation))
            }
        }
        routedSequenceWaiters = pending
    }
}
