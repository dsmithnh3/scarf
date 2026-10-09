import Foundation

public actor AgentRegistry {
    private var backends: [AgentID: any AgentBackend] = [:]

    public init() {}

    public var count: Int {
        backends.count
    }

    public func register(_ backend: any AgentBackend) {
        backends[backend.id] = backend
    }

    public func backend(for id: AgentID) -> (any AgentBackend)? {
        backends[id]
    }

    public func availableBackends() -> [any AgentBackend] {
        backends.values.sorted { lhs, rhs in
            lhs.id.rawValue < rhs.id.rawValue
        }
    }
}
