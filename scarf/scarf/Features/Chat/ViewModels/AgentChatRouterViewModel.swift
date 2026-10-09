import Foundation
import Observation
import ScarfCore

/// Compatibility router for the staged multi-agent chat migration.
///
/// A project handoff must be resolved *before* the legacy `ChatView` renders,
/// because that view consumes `AppCoordinator.pendingProjectChat` on appear.
/// Old/missing project records remain Hermes. Hermes projects use `AgentChat`
/// when `scarf.experimental.hermesAgentChat` is on (default); turning the flag
/// off restores the ChatView escape hatch. Explicit non-Hermes preferences are
/// routed through `AgentRuntime`; an unavailable backend is surfaced rather
/// than silently falling back to Hermes.
@MainActor
@Observable
final class AgentChatRouterViewModel {
    enum Route {
        case legacy(projectPath: String?)
        case resolving(projectPath: String)
        case agent(project: ScarfProject, viewModel: AgentChatViewModel)
        case unavailable(projectPath: String, backendID: AgentID?, message: String)
    }

    private let context: ServerContext
    private let projectStore: ProjectStore
    private let runtime: AgentRuntime
    /// Injectable for tests. Production reads `HermesAgentChatOptIn.isEnabled`.
    private let isHermesAgentChatEnabled: () -> Bool

    private(set) var route: Route = .legacy(projectPath: nil)
    private var requestedProjectPath: String?

    init(
        context: ServerContext,
        isHermesAgentChatEnabled: @escaping () -> Bool = { HermesAgentChatOptIn.isEnabled }
    ) {
        self.context = context
        self.projectStore = ProjectStore(context: context)
        self.runtime = AgentRuntime(context: context)
        self.isHermesAgentChatEnabled = isHermesAgentChatEnabled
    }

    /// Resolve one project handoff. Repeated calls for the same path are cheap,
    /// while a newer path supersedes an older in-flight transport read.
    func resolve(projectPath: String) async {
        if requestedProjectPath == projectPath {
            switch route {
            case .resolving, .agent, .unavailable, .legacy:
                return
            }
        }

        requestedProjectPath = projectPath
        route = .resolving(projectPath: projectPath)

        let store = projectStore
        let record = await Task.detached(priority: .userInitiated) {
            store.loadDetailed(projectPath: projectPath)
        }.value

        guard requestedProjectPath == projectPath else { return }

        switch record {
        case .absent:
            // Pre-multi-agent projects intentionally have no preference record.
            // Their compatibility default is Hermes.
            route = .legacy(projectPath: projectPath)

        case .unreadable(let path):
            route = .unavailable(
                projectPath: projectPath,
                backendID: nil,
                message: "Scarf could not read the project record at \(path). The chat backend was not changed or guessed."
            )

        case .loaded(let project):
            let preferred = project.preferredAgentID
            if preferred == .hermes, !isHermesAgentChatEnabled() {
                route = .legacy(projectPath: projectPath)
                return
            }

            guard let controller = await runtime.conversationController(for: project) else {
                let detail = context.isRemote
                    ? "\(preferred.rawValue) is not available in this remote window."
                    : "\(preferred.rawValue) is not available on this Mac."
                route = .unavailable(
                    projectPath: projectPath,
                    backendID: preferred,
                    message: detail
                )
                return
            }

            let backendID = preferred
            let serverContext = context
            let agentRuntime = runtime

            // Only Hermes reads `HermesCapabilities` (ACP version/feature
            // flags) today — Claude has no such probe, and the view model
            // only consults this loader on the Hermes boot/send paths.
            var capabilitiesLoader: AgentChatViewModel.CapabilitiesLoader?
            if backendID == .hermes {
                let capabilitiesStore = HermesCapabilitiesStore(context: serverContext)
                capabilitiesLoader = { await capabilitiesStore.confirmedCapabilities() }
            }

            route = .agent(
                project: project,
                viewModel: AgentChatViewModel(
                    controller: controller,
                    backendID: backendID,
                    workingDirectory: URL(fileURLWithPath: project.rootPath),
                    extensionCatalogLoader: {
                        // Hermes walks the installed home. Claude merges live
                        // initialize `agents` into the empty static skills stub
                        // — never scrape ~/.claude.
                        if backendID == .hermes {
                            return AgentExtensionCatalogs.makeCatalog(
                                fromHermesHome: serverContext
                            )
                        }
                        let base = AgentExtensionCatalogs.makeCatalog()
                        guard let backend = await agentRuntime.backend(for: project) else {
                            return base
                        }
                        let live = await backend.discoveredExtensions()
                        guard !live.isEmpty else { return base }
                        return AgentExtensionCatalog(entries: base.entries + live)
                    },
                    modelsLoader: {
                        guard let backend = await agentRuntime.backend(for: project) else {
                            return []
                        }
                        return (try? await backend.models()) ?? []
                    },
                    serverContext: serverContext,
                    projectPath: project.rootPath,
                    authHealthLoader: {
                        guard let backend = await agentRuntime.backend(for: project) else {
                            return .notProbed
                        }
                        return await backend.authHealth()
                    },
                    capabilitiesLoader: capabilitiesLoader
                )
            )
        }
    }

    /// A plain Chat navigation with no project handoff remains on the legacy
    /// Hermes surface unless an agent project conversation is already active.
    func useLegacyWhenIdle() {
        guard requestedProjectPath == nil else { return }
        route = .legacy(projectPath: nil)
    }

    /// Called after the routed project handoff has been consumed by either the
    /// legacy or generic surface. The resolved route itself is intentionally
    /// retained so returning to Chat restores the same surface for this window.
    func markHandoffConsumed(projectPath: String) {
        guard requestedProjectPath == projectPath else { return }
    }
}
