import Foundation
import ScarfCore

/// App-level composition root for agent backends.
///
/// Registration is intentionally separate from view routing. Existing Hermes
/// UI continues to use its production ACP paths until the shared chat/session
/// surface is migrated and verified. This runtime simply establishes one
/// canonical registry/coordinator for new multi-agent features.
actor AgentRuntime {
    static let shared = AgentRuntime()

    let registry: AgentRegistry
    let coordinator: AgentCoordinator

    private var isConfigured = false

    init() {
        let registry = AgentRegistry()
        self.registry = registry
        self.coordinator = AgentCoordinator(registry: registry)
    }

    func configureIfNeeded() async {
        guard !isConfigured else { return }
        isConfigured = true

        // Hermes remains first and is the compatibility/default backend.
        await coordinator.register(HermesBackend(context: .local))

        // Claude Code is registered as an additional local backend. Merely
        // registering it does not launch a process or alter existing Hermes
        // navigation/chat behavior.
        await coordinator.register(ClaudeCodeBackend())
    }

    func backend(for project: ScarfProject) async -> (any AgentBackend)? {
        await configureIfNeeded()
        return await coordinator.backend(for: project.preferredAgentID)
    }
}
