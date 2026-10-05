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
    private let controller: AgentConversationController
    private let backendID: AgentID
    private let workingDirectory: URL
    private let baseSlashRegistry: AgentSlashCommandRegistry
    private var slashHintPresenter: AgentSlashHintPresenter

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

    @ObservationIgnored
    private var stateTask: Task<Void, Never>?

    init(
        controller: AgentConversationController,
        backendID: AgentID,
        workingDirectory: URL,
        slashHintPresenter: AgentSlashHintPresenter? = nil
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
        } catch {
            startupError = String(describing: error)
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

    /// Rebuild the hint registry when Hermes ACP advertises live commands.
    /// Empty discovery keeps the static Scarf + Hermes fallback catalogs.
    private func applyDiscoveredSlashCommands(from snapshot: AgentConversationState) {
        if snapshot.discoveredSlashCommands.isEmpty {
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
