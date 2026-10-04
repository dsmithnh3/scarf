import Foundation

actor AgentRegistry {
    private var backends: [AgentID: any AgentBackend] = [:]

    var count: Int {
        backends.count
    }

    func register(_ backend: any AgentBackend) {
        backends[backend.id] = backend
    }

    func backend(for id: AgentID) -> (any AgentBackend)? {
        backends[id]
    }

    func availableBackends() -> [any AgentBackend] {
        backends.values.sorted { lhs, rhs in
            lhs.id.rawValue < rhs.id.rawValue
        }
    }
}
