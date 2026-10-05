import Foundation

public enum AgentCoordinatorError: Error, Equatable, Sendable {
    case backendUnavailable(AgentID)
}

/// An event forwarded by `AgentCoordinator` with its originating backend.
///
/// `AgentEvent` itself intentionally stays backend-neutral. This envelope gives
/// higher-level conversation controllers enough routing context to prevent an
/// event from one registered runtime from mutating another runtime's UI state.
public struct AgentRoutedEvent: Equatable, Sendable {
    public let sequence: UInt64
    public let backendID: AgentID
    public let event: AgentEvent

    public init(sequence: UInt64, backendID: AgentID, event: AgentEvent) {
        self.sequence = sequence
        self.backendID = backendID
        self.event = event
    }
}

/// Routes backend-neutral agent operations to the selected runtime and merges
/// backend event streams into one application-facing stream.
public actor AgentCoordinator {
    /// Compatibility stream used by existing generic consumers.
    public nonisolated let events: AsyncStream<AgentEvent>

    /// Routed stream for consumers that must distinguish simultaneously
    /// registered backends.
    public nonisolated let routedEvents: AsyncStream<AgentRoutedEvent>

    private let registry: AgentRegistry
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let routedEventContinuation: AsyncStream<AgentRoutedEvent>.Continuation
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
        let stream = backend.events
        forwardingTasks[backendID] = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.forward(event, from: backendID)
            }
        }
    }

    public func backend(for id: AgentID) async -> (any AgentBackend)? {
        await registry.backend(for: id)
    }

    public func availableBackends() async -> [any AgentBackend] {
        await registry.availableBackends()
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

    private func forward(_ event: AgentEvent, from backendID: AgentID) {
        routedEventSequence &+= 1
        let routed = AgentRoutedEvent(
            sequence: routedEventSequence,
            backendID: backendID,
            event: event
        )
        routedEventContinuation.yield(routed)
        eventContinuation.yield(event)
    }
}