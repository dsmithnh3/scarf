import Foundation
import ScarfCore

/// Read-only status snapshot used by agent-aware UI surfaces.
///
/// This deliberately carries no selection or mutation API. Exposing backend
/// health in Settings must not change the backend used by existing Hermes chat.
/// `executablePath` is the discovered CLI path when known; `nil` means not
/// found (never a guessed fallback). `authHealth` is only non-`.notProbed`
/// when a verified credential probe exists (Hermes today).
struct AgentBackendStatusSnapshot: Identifiable, Equatable, Sendable {
    let id: AgentID
    let displayName: String
    let executablePath: String?
    let status: AgentInstallationStatus
    let authHealth: AgentAuthHealth

    init(
        id: AgentID,
        displayName: String,
        executablePath: String?,
        status: AgentInstallationStatus,
        authHealth: AgentAuthHealth = .notProbed
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.status = status
        self.authHealth = authHealth
    }
}

/// Shared formatting for provider diagnostics detail lines (Settings + tests).
enum AgentBackendStatusFormatting {
    static func detailText(for snapshot: AgentBackendStatusSnapshot) -> String {
        let base: String
        switch snapshot.status {
        case .available(let version):
            var parts: [String] = []
            if let version, !version.isEmpty {
                parts.append(version)
            }
            if let path = snapshot.executablePath, !path.isEmpty {
                parts.append(path)
            }
            if parts.isEmpty {
                base = snapshot.id == .hermes ? "Hermes runtime detected" : "Runtime detected"
            } else {
                base = parts.joined(separator: " · ")
            }
        case .notInstalled:
            base = snapshot.id == .claudeCode
                ? "Claude Code executable was not found"
                : "Runtime executable was not found"
        case .unavailable(let reason):
            base = reason
        }
        return AgentAuthHealthFormatting.appendingDetailSuffix(
            to: base,
            health: snapshot.authHealth
        )
    }
}

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

    /// Probe registered backends without changing routing or starting a session.
    func statusSnapshots() async -> [AgentBackendStatusSnapshot] {
        await configureIfNeeded()
        let backends = await registry.availableBackends()
        var snapshots: [AgentBackendStatusSnapshot] = []
        snapshots.reserveCapacity(backends.count)

        for backend in backends {
            snapshots.append(
                AgentBackendStatusSnapshot(
                    id: backend.id,
                    displayName: backend.displayName,
                    executablePath: backend.resolvedExecutablePath(),
                    status: await backend.installationStatus(),
                    authHealth: await backend.authHealth()
                )
            )
        }
        return snapshots
    }

    func backend(for project: ScarfProject) async -> (any AgentBackend)? {
        await configureIfNeeded()

        // A project copied from a local Mac can carry Claude as its preference.
        // If opened through a remote window before remote Claude support ships,
        // return nil rather than silently falling back to a different runtime.
        return await coordinator.backend(for: project.preferredAgentID)
    }

    /// Build a backend-neutral conversation controller only when the project's
    /// preferred runtime is registered in this window/profile context.
    ///
    /// This is intentionally a factory rather than a global controller: each
    /// chat owns its own session lifecycle/state while sharing the context-bound
    /// coordinator and registered backend processes.
    ///
    /// Controllers are wired to ``AgentConversationIdentityStore`` at
    /// `HermesPathSet.agentConversationIdentities` so start/resume persist and
    /// relaunch can restore without inventing a second conversation state.
    func conversationController(for project: ScarfProject) async -> AgentConversationController? {
        await configureIfNeeded()
        guard await coordinator.backend(for: project.preferredAgentID) != nil else {
            return nil
        }
        return AgentConversationController.makePersisting(
            coordinator: coordinator,
            conversationID: project.id.uuidString,
            hermesHome: context.paths.home
        )
    }
}
