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

    private let coordinator: AgentCoordinator
    private let stateContinuation: AsyncStream<AgentConversationState>.Continuation
    private var state = AgentConversationState()
    private var activeSession: AgentSession?
    private var activeBackendID: AgentID?
    private var eventTask: Task<Void, Never>?

    public init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator

        var continuation: AsyncStream<AgentConversationState>.Continuation!
        self.stateUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            continuation = $0
        }
        self.stateContinuation = continuation
        continuation.yield(state)
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
        let session = try await coordinator.createSession(
            backendID: backendID,
            configuration: configuration
        )
        activeBackendID = backendID
        activeSession = session
        state = AgentConversationState()
        state.apply(.sessionStarted(session))
        publishState()
        return session
    }

    @discardableResult
    public func resumeSession(_ session: AgentSession) async throws -> AgentSession {
        await ensureEventLoop()
        let resumed = try await coordinator.resumeSession(session)
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
                throw error
            }
        }
        activeBackendID = resumed.backendID
        activeSession = resumed
        state = AgentConversationState()
        state.apply(.sessionStarted(resumed))
        publishState()
        return resumed
    }

    public func send(_ content: String) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }

        let message = AgentMessage(role: .user, content: content)
        state.beginUserTurn(content)
        publishState()

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
            throw error
        }
    }

    public func respond(to request: AgentPermissionRequest, optionID: String) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        try await coordinator.respond(to: request, optionID: optionID, in: session)
    }

    public func cancelPermission(_ request: AgentPermissionRequest) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        try await coordinator.cancelPermission(request, in: session)
    }

    public func cancel() async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        try await coordinator.cancel(session: session)
    }

    public func close() async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }
        try await coordinator.close(session: session)
        activeSession = nil
        state.apply(.sessionClosed)
        publishState()
    }

    public func stateSnapshot() -> AgentConversationState {
        state
    }

    private func sameSession(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        lhs.backendID == rhs.backendID && lhs.id == rhs.id
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
        guard routed.backendID == activeBackendID else { return }

        // Scoped backends can host multiple sessions simultaneously. Ignore an
        // event carrying a different session id; unscoped legacy backends retain
        // their previous backend-only routing behavior for compatibility.
        if let routedSessionID = routed.sessionID {
            guard routedSessionID == activeSession?.id else { return }
        }

        state.apply(routed.event)

        if case .sessionStarted(let session) = routed.event {
            activeSession = session
        }

        publishState()
    }

    private func publishState() {
        stateContinuation.yield(state)
    }
}
