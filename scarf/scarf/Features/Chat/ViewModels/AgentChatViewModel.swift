import Foundation
import Observation
import ScarfCore

/// Thin macOS observation adapter around `AgentConversationController`.
///
/// Backend/session behavior stays in ScarfCore. This type only mirrors state
/// snapshots onto the main actor and delegates user actions to the controller.
/// The existing Hermes `ChatViewModel` remains unchanged and authoritative for
/// the production Hermes chat path during the migration.
@MainActor
@Observable
final class AgentChatViewModel {
    typealias ExtensionCatalogLoader = @Sendable () async -> AgentExtensionCatalog
    typealias ModelsLoader = @Sendable () async -> [AgentModel]

    private let controller: AgentConversationController
    private let backendID: AgentID
    private let workingDirectory: URL
    private let baseSlashRegistry: AgentSlashCommandRegistry
    private var slashHintPresenter: AgentSlashHintPresenter
    private let extensionCatalogLoader: ExtensionCatalogLoader
    private let modelsLoader: ModelsLoader

    private(set) var state = AgentConversationState()
    private(set) var isStarted = false
    private(set) var startupError: String?

    /// Composer draft owned by the view model so slash-hint presentation can
    /// update with every keystroke without duplicating registry logic in SwiftUI.
    var draft = "" {
        didSet { refreshSlashHints() }
    }

    private(set) var slashHintPresentation = AgentSlashHintPresentation(
        isVisible: false,
        query: "",
        hints: [],
        catalogIsEmpty: false
    )

    /// Read-only extensions browser presentation. Empty until ``loadExtensionsCatalog()``.
    private(set) var extensionBrowserPresentation = AgentExtensionBrowserPresenter.make(
        catalog: AgentExtensionCatalog(),
        backendID: .hermes,
        capabilities: []
    )
    private(set) var isLoadingExtensions = false

    /// Read-only models list from the active backend's ``AgentBackend/models()``.
    /// Claude fills this from control initialize after session start; Hermes
    /// fills it from the configured provider's Rich Chat catalog.
    private(set) var availableModels: [AgentModel] = []
    private(set) var isLoadingModels = false

    @ObservationIgnored
    private var stateTask: Task<Void, Never>?

    init(
        controller: AgentConversationController,
        backendID: AgentID,
        workingDirectory: URL,
        slashHintPresenter: AgentSlashHintPresenter? = nil,
        extensionCatalogLoader: ExtensionCatalogLoader? = nil,
        modelsLoader: ModelsLoader? = nil
    ) {
        self.controller = controller
        self.backendID = backendID
        self.workingDirectory = workingDirectory
        let presenter = slashHintPresenter ?? AgentSlashHintPresenter(
            backendID: backendID,
            capabilities: AgentSlashHintPresenter.defaultCapabilities(for: backendID)
        )
        self.baseSlashRegistry = presenter.registry
        self.slashHintPresenter = presenter
        self.extensionCatalogLoader = extensionCatalogLoader ?? {
            AgentExtensionCatalogs.makeCatalog()
        }
        self.modelsLoader = modelsLoader ?? { [] }
        self.extensionBrowserPresentation = AgentExtensionBrowserPresenter.make(
            catalog: AgentExtensionCatalog(),
            backendID: backendID,
            capabilities: AgentSlashHintPresenter.defaultCapabilities(for: backendID)
        )
        observeState()
        refreshSlashHints()
    }

    deinit {
        stateTask?.cancel()
    }

    var isSlashHintMenuVisible: Bool {
        slashHintPresentation.isVisible
    }

    var slashHints: [AgentSlashCommandHint] {
        slashHintPresentation.hints
    }

    /// FIFO head of the permission coordinator, if any. Drives the Scarf-native
    /// permission card in multi-agent project chat.
    var permissionPresentation: AgentPermissionPresentation? {
        AgentPermissionPresenter.presentation(from: state)
    }

    func start() async {
        guard !isStarted else { return }
        startupError = nil

        do {
            _ = try await controller.startOrRestorePersistedSession(
                backendID: backendID,
                configuration: AgentSessionConfiguration(
                    workingDirectory: workingDirectory
                )
            )
            isStarted = true
            await refreshAvailableModels()
        } catch {
            startupError = String(describing: error)
        }
    }

    /// Load the read-only extension catalog for the browse sheet.
    func loadExtensionsCatalog() async {
        guard !isLoadingExtensions else { return }
        isLoadingExtensions = true
        defer { isLoadingExtensions = false }

        let catalog = await extensionCatalogLoader()
        let capabilities = AgentSlashHintPresenter.defaultCapabilities(for: backendID)
        extensionBrowserPresentation = AgentExtensionBrowserPresenter.make(
            catalog: catalog,
            backendID: backendID,
            capabilities: capabilities
        )
    }

    /// Refresh the read-only model badge from the backend's models() bridge.
    func refreshAvailableModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        availableModels = await modelsLoader()
    }

    /// Display label for the read-only model badge. Prefers a single model
    /// when the backend advertises exactly one; otherwise a count.
    var modelBadgeLabel: String? {
        switch availableModels.count {
        case 0:
            return nil
        case 1:
            return availableModels[0].displayName
        default:
            return "\(availableModels.count) models"
        }
    }

    func send(_ content: String) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await controller.send(trimmed)
    }

    func sendDraft() async throws {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        try await send(message)
    }

    /// Accept a slash hint into the composer. Does not send — the user can
    /// still edit arguments before submitting.
    func acceptSlashHint(_ hint: AgentSlashCommandHint) {
        guard let insertion = slashHintPresenter.accepting(hint, draft: draft) else { return }
        draft = insertion
    }

    func cancel() async throws {
        try await controller.cancel()
    }

    func close() async {
        guard isStarted else { return }
        do {
            try await controller.close()
        } catch {
            // Teardown is best effort. The backend process/channel owns its own
            // bounded shutdown path, and leaving Chat must not trap the user on
            // the surface because a close notification failed.
        }
        isStarted = false
    }

    func respond(to request: AgentPermissionRequest, optionID: String) async throws {
        try await controller.respond(to: request, optionID: optionID)
    }

    func cancelPermission(_ request: AgentPermissionRequest) async throws {
        try await controller.cancelPermission(request)
    }

    private func refreshSlashHints() {
        slashHintPresentation = slashHintPresenter.presentation(for: draft)
    }

    /// Rebuild the hint registry when the backend advertises live commands.
    /// Hermes keeps its static fallback when discovery is empty. Claude replaces
    /// its (statically empty) catalog with initialize / `commands_changed` rows.
    private func applyDiscoveredSlashCommands(from snapshot: AgentConversationState) {
        if backendID == .claudeCode {
            slashHintPresenter.registry = baseSlashRegistry.mergingLiveClaudeCommands(
                snapshot.discoveredSlashCommands
            )
        } else if snapshot.discoveredSlashCommands.isEmpty {
            slashHintPresenter.registry = baseSlashRegistry
        } else {
            slashHintPresenter.registry = baseSlashRegistry.mergingLiveHermesACPCommands(
                snapshot.discoveredSlashCommands
            )
        }
        refreshSlashHints()
    }

    private func observeState() {
        let stream = controller.stateUpdates
        stateTask = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.state = snapshot
                self?.applyDiscoveredSlashCommands(from: snapshot)
            }
        }
    }
}
