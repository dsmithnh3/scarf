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

    /// Models list from the active backend's ``AgentBackend/models()``.
    /// Claude fills this from control initialize after session start; Hermes
    /// fills it from the configured provider's Rich Chat catalog.
    private(set) var availableModels: [AgentModel] = []
    private(set) var isLoadingModels = false
    /// Claude-only launch model. Nil means CLI default (no `--model` flag).
    private(set) var selectedModelID: String?
    private(set) var isChangingModel = false

    @ObservationIgnored
    private var stateTask: Task<Void, Never>?
    /// Tracks Claude initialize/commands_changed so models + skills refresh
    /// after the async handshake writes discovery caches.
    @ObservationIgnored
    private var lastDiscoveredCommandSignature: String?

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

    /// Claude exposes a launch-time model menu. Hermes stays badge-only —
    /// no ACP `set_model` in this slice.
    var supportsModelPicker: Bool {
        backendID == .claudeCode
    }

    func start() async {
        guard !isStarted else { return }
        startupError = nil

        do {
            _ = try await controller.startOrRestorePersistedSession(
                backendID: backendID,
                configuration: AgentSessionConfiguration(
                    workingDirectory: workingDirectory,
                    modelID: selectedModelID
                )
            )
            isStarted = true
            await refreshAvailableModels()
            if backendID == .claudeCode {
                await loadExtensionsCatalog()
            }
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

    /// Refresh models from the backend's models() bridge.
    func refreshAvailableModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        availableModels = await modelsLoader()
    }

    /// Claude: close and recreate the session with `--model`. Same id is a
    /// no-op. Hermes callers must not use this path (`supportsModelPicker`).
    func selectModel(id: String) async {
        guard supportsModelPicker else { return }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedModelID else { return }
        guard !isChangingModel else { return }

        isChangingModel = true
        defer { isChangingModel = false }

        selectedModelID = trimmed
        await close()
        await start()
    }

    /// Badge / menu label. Selected Claude model wins; otherwise a single
    /// advertised name, a count, or nil while empty.
    var modelBadgeLabel: String? {
        if let selectedModelID,
           let match = availableModels.first(where: { $0.id == selectedModelID }) {
            return match.displayName
        }
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
                self?.refreshDiscoveryAfterClaudeHandshake(from: snapshot)
            }
        }
    }

    /// Claude populate models()/discoveredExtensions after initialize on a
    /// background consume loop. Re-read them when slash discovery updates.
    private func refreshDiscoveryAfterClaudeHandshake(from snapshot: AgentConversationState) {
        guard backendID == .claudeCode else { return }
        let signature = snapshot.discoveredSlashCommands.map(\.name).joined(separator: "\u{1e}")
        guard signature != lastDiscoveredCommandSignature else { return }
        lastDiscoveredCommandSignature = signature
        Task { [weak self] in
            await self?.refreshAvailableModels()
            await self?.loadExtensionsCatalog()
        }
    }
}
