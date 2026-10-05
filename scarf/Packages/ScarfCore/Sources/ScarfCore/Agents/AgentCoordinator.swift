import Foundation

public enum AgentCoordinatorError: Error, Equatable, Sendable {
    case backendUnavailable(AgentID)
}

/// An event forwarded by `AgentCoordinator` with its originating backend and,
/// when available, the session that produced it.
///
/// `AgentEvent` itself intentionally stays backend-neutral. This envelope gives
/// higher-level conversation controllers enough routing context to prevent an
/// event from one registered runtime or session from mutating another UI state.
public struct AgentRoutedEvent: Equatable, Sendable {
    public let sequence: UInt64
    public let backendID: AgentID
    public let sessionID: String?
    public let event: AgentEvent

    public init(
        sequence: UInt64,
        backendID: AgentID,
        sessionID: String? = nil,
        event: AgentEvent
    ) {
        self.sequence = sequence
        self.backendID = backendID
        self.sessionID = sessionID
        self.event = event
    }
}

/// Routes backend-neutral agent operations to the selected runtime and merges
/// backend event streams into application-facing streams.
public actor AgentCoordinator {
    /// Compatibility stream used by existing generic consumers.
    public nonisolated let events: AsyncStream<AgentEvent>

    /// Compatibility routed stream. New conversation controllers should use
    /// `subscribeToRoutedEvents()` so every window receives an independent
    /// subscription rather than sharing one iterator/buffer.
    public nonisolated let routedEvents: AsyncStream<AgentRoutedEvent>

    private let registry: AgentRegistry
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let routedEventContinuation: AsyncStream<AgentRoutedEvent>.Continuation
    private var routedEventSubscribers: [UUID: AsyncStream<AgentRoutedEvent>.Continuation] = [:]
    private var forwardingTasks: [AgentID: Task<Void, Never>] = [:]
    private var routedEventSequence: UInt64 = 0

    public init(registry: AgentRegistry = AgentRegistry()) {
        self.registry = registry

        var eventContinuation: AsyncStream<AgentEvent>.Continuation!
        self.events = AsyncStream { eventContinuation = $0 }
        self.eventContinuation = eventContinuation

        var routedEventContinuation: AsyncStream<AgentRoutedEvent>.Continuation!
        self.routedEvents = AsyncStream { routedEventContinuation = $0 }
        self.routedEventContinuation = routedEventContinuation
    }

    public func register(_ backend: any AgentBackend) async {
        forwardingTasks.removeValue(forKey: backend.id)?.cancel()
        await registry.register(backend)

        let backendID = backend.id
        if let scopedBackend = backend as? any SessionScopedAgentBackend {
            let stream = scopedBackend.sessionEvents
            forwardingTasks[backendID] = Task { [weak self] in
                for await scopedEvent in stream {
                    guard !Task.isCancelled else { break }
                    await self?.forward(
                        scopedEvent.event,
                        from: backendID,
                        sessionID: scopedEvent.sessionID
                    )
                }
            }
        } else {
            let stream = backend.events
            forwardingTasks[backendID] = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.forward(event, from: backendID, sessionID: nil)
                }
            }
        }
    }

    public func backend(for id: AgentID) async -> (any AgentBackend)? {
        await registry.backend(for: id)
    }

    public func availableBackends() async -> [any AgentBackend] {
        await registry.availableBackends()
    }

    /// Creates an independent routed-event subscription for one consumer.
    ///
    /// This is the multi-window-safe observation seam. Every subscription gets
    /// each subsequently forwarded event; cancellation removes only that
    /// subscriber and does not affect other conversations.
    public func subscribeToRoutedEvents() -> AsyncStream<AgentRoutedEvent> {
        let subscriberID = UUID()
        var continuation: AsyncStream<AgentRoutedEvent>.Continuation!
        let stream = AsyncStream<AgentRoutedEvent>(bufferingPolicy: .bufferingNewest(256)) {
            continuation = $0
        }
        routedEventSubscribers[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRoutedEventSubscriber(subscriberID) }
        }
        return stream
    }

    public func createSession(
        backendID: AgentID = .hermes,
        configuration: AgentSessionConfiguration
    ) async throws -> AgentSession {
        let backend = try await requiredBackend(backendID)
        return try await backend.createSession(configuration: configuration)
    }

    public func resumeSession(_ session: AgentSession) async throws -> AgentSession {
        let backend = try await requiredBackend(session.backendID)
        return try await backend.resumeSession(session)
    }

    public func send(_ message: AgentMessage, in session: AgentSession) async throws {
        let backend = try await requiredBackend(session.backendID)
        try await backend.send(message, in: session)
    }

    public func respond(
        to request: AgentPermissionRequest,
        optionID: String,
        in session: AgentSession
    ) async throws {
        let backend = try await requiredBackend(session.backendID)
        try await backend.respond(to: request, optionID: optionID, in: session)
    }

    public func cancelPermission(
        _ request: AgentPermissionRequest,
        in session: AgentSession
    ) async throws {
        let backend = try await requiredBackend(session.backendID)
        try await backend.cancelPermission(request, in: session)
    }

    public func cancel(session: AgentSession) async throws {
        let backend = try await requiredBackend(session.backendID)
        await backend.cancel(session: session)
    }

    public func close(session: AgentSession) async throws {
        let backend = try await requiredBackend(session.backendID)
        await backend.close(session: session)
    }

    /// Sequence of the most recently forwarded routed event.
    /// Useful for deterministic consumers/tests that need to wait until their
    /// event loop has observed everything already emitted by registered backends.
    public func latestRoutedEventSequence() -> UInt64 {
        routedEventSequence
    }

    private func requiredBackend(_ id: AgentID) async throws -> any AgentBackend {
        guard let backend = await registry.backend(for: id) else {
            throw AgentCoordinatorError.backendUnavailable(id)
        }
        return backend
    }

    private func removeRoutedEventSubscriber(_ id: UUID) {
        routedEventSubscribers.removeValue(forKey: id)
    }

    private func forward(
        _ event: AgentEvent,
        from backendID: AgentID,
        sessionID: String?
    ) {
        routedEventSequence &+= 1
        let routed = AgentRoutedEvent(
            sequence: routedEventSequence,
            backendID: backendID,
            sessionID: sessionID,
            event: event
        )

        routedEventContinuation.yield(routed)
        for continuation in routedEventSubscribers.values {
            continuation.yield(routed)
        }
        eventContinuation.yield(event)
    }
}
