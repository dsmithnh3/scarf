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
        ensureEventLoop()
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
        ensureEventLoop()
        let resumed = try await coordinator.resumeSession(session)
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

    private func ensureEventLoop() {
        guard eventTask == nil else { return }
        let stream = coordinator.routedEvents
        eventTask = Task { [weak self] in
            for await routed in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(routed)
            }
        }
    }

    private func consume(_ routed: AgentRoutedEvent) {
        guard routed.backendID == activeBackendID else { return }
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
