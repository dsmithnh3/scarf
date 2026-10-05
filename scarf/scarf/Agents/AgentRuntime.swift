import Foundation
import ScarfCore

/// Per-window/profile composition root for agent backends.
///
/// Scarf's existing Hermes UI is server-context scoped: local and SSH windows
/// can run side-by-side, and a remote profile switch rebuilds the entire
/// context-bound root against a different HERMES_HOME. The agent runtime must
/// have the same lifetime. A process-wide singleton would incorrectly route a
/// remote Hermes project through the local machine.
///
/// Registration remains separate from view routing. Existing Hermes chat/UI
/// continues to use its production ACP path until the shared surface is
/// migrated and verified.
actor AgentRuntime {
    let context: ServerContext
    let registry: AgentRegistry
    let coordinator: AgentCoordinator

    private var isConfigured = false

    init(context: ServerContext) {
        self.context = context
        let registry = AgentRegistry()
        self.registry = registry
        self.coordinator = AgentCoordinator(registry: registry)
    }

    func configureIfNeeded() async {
        guard !isConfigured else { return }
        isConfigured = true

        // Hermes remains first, default, and available for every context
        // Scarf already supports, including SSH and profile-scoped remotes.
        await coordinator.register(HermesBackend(context: context))

        // The first Claude implementation is deliberately local-only. Do not
        // advertise it in remote windows until SSH execution is implemented
        // and regression-tested independently of Hermes remote behavior.
        if !context.isRemote {
            await coordinator.register(ClaudeCodeBackend())
        }
    }

    func backend(for project: ScarfProject) async -> (any AgentBackend)? {
        await configureIfNeeded()

        // A project copied from a local Mac can carry Claude as its preference.
        // If opened through a remote window before remote Claude support ships,
        // return nil rather than silently falling back to a different runtime.
        return await coordinator.backend(for: project.preferredAgentID)
    }
}
