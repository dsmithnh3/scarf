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
    private let coordinator: AgentCoordinator
    private var state = AgentConversationState()
    private var activeSession: AgentSession?
    private var activeBackendID: AgentID?
    private var eventTask: Task<Void, Never>?
    private var lastObservedSequence: UInt64 = 0

    public init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        eventTask?.cancel()
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
        state.apply(.sessionStarted(session))
        return session
    }

    @discardableResult
    public func resumeSession(_ session: AgentSession) async throws -> AgentSession {
        ensureEventLoop()
        let resumed = try await coordinator.resumeSession(session)
        activeBackendID = resumed.backendID
        activeSession = resumed
        state.apply(.sessionStarted(resumed))
        return resumed
    }

    public func send(_ content: String) async throws {
        guard let session = activeSession else {
            throw AgentConversationControllerError.noActiveSession
        }

        let message = AgentMessage(role: .user, content: content)
        state.beginUserTurn(content)
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
        state.apply(.sessionClosed)
    }

    public func stateSnapshot() -> AgentConversationState {
        state
    }

    /// Wait until this controller's event loop has observed every routed event
    /// already forwarded by the coordinator when this method begins.
    ///
    /// This is primarily a deterministic synchronization seam for tests, but is
    /// safe for callers that need an explicit flush point before reading state.
    public func waitForEventsToDrain() async {
        let target = await coordinator.latestRoutedEventSequence()
        while lastObservedSequence < target {
            await Task.yield()
        }
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
        lastObservedSequence = max(lastObservedSequence, routed.sequence)
        guard routed.backendID == activeBackendID else { return }
        state.apply(routed.event)

        switch routed.event {
        case .sessionStarted(let session):
            activeSession = session
        case .sessionClosed:
            break
        default:
            break
        }
    }
}
