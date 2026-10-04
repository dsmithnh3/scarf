import Foundation

public enum AgentCoordinatorError: Error, Equatable, Sendable {
    case backendUnavailable(AgentID)
}

/// Routes backend-neutral agent operations to the selected runtime and merges
/// backend event streams into one application-facing stream.
public actor AgentCoordinator {
    public nonisolated let events: AsyncStream<AgentEvent>

    private let registry: AgentRegistry
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private var forwardingTasks: [AgentID: Task<Void, Never>] = [:]

    public init(registry: AgentRegistry = AgentRegistry()) {
        self.registry = registry
        var continuation: AsyncStream<AgentEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func register(_ backend: any AgentBackend) async {
        forwardingTasks.removeValue(forKey: backend.id)?.cancel()
        await registry.register(backend)

        let stream = backend.events
        forwardingTasks[backend.id] = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.forward(event)
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

    private func requiredBackend(_ id: AgentID) async throws -> any AgentBackend {
        guard let backend = await registry.backend(for: id) else {
            throw AgentCoordinatorError.backendUnavailable(id)
        }
        return backend
    }

    private func forward(_ event: AgentEvent) {
        eventContinuation.yield(event)
    }
}
