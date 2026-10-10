import Foundation
import Observation
import ScarfCore

/// Outcome of applying a project's bound model preset to a fresh Hermes
/// session at boot. Mirrors `ProjectModelPresetApplier.Outcome` (ScarfCore),
/// but expressed against the backend-neutral `AgentConversationController`
/// instead of a Hermes-specific `ACPClient` + session id, so it can be
/// produced by a test seam (``AgentChatViewModel/init(controller:backendID:workingDirectory:slashHintPresenter:extensionCatalogLoader:modelsLoader:serverContext:projectPath:fallbackSessionIDsLoader:sessionAttributor:authHealthLoader:autoAcceptStore:capabilitiesLoader:projectPresetApplier:)``)
/// without touching disk or the Keychain.
enum AgentProjectPresetOutcome: Equatable {
    /// The project has no preset binding — the global default applies.
    case noBinding
    /// The manifest names a preset id that isn't in the store (deleted).
    case presetMissing(id: String)
    /// The preset store couldn't be read.
    case storeUnreadable(message: String)
    /// Hermes accepted the preset for this session.
    case applied(ModelPreset)
    /// Hermes refused `session/set_model`; the session stays on the
    /// config.yaml default.
    case rejected(ModelPreset, message: String)
}

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
    /// Credential probe for the "no credentials detected" boot banner.
    /// Defaults to ``AgentAuthHealth/notProbed`` (never guesses).
    typealias AuthHealthLoader = () async -> AgentAuthHealth
    /// Live Hermes version/feature flags gating idle `/queue` & `/steer`
    /// rewrite rules and the auto-accept-edits boot capability check.
    /// Defaults to ``HermesCapabilities/empty`` (sub-floor behavior).
    typealias CapabilitiesLoader = () async -> HermesCapabilities
    /// Test seam for the project model-preset boot step. `nil` (the
    /// production default) runs the real `ProjectModelPresetReader` +
    /// `ModelPresetService` + `controller.setSessionModel` sequence.
    typealias ProjectPresetApplier = (String) async -> AgentProjectPresetOutcome
    /// Session ids previously attributed (by legacy `ChatView`) to this
    /// project, most-recent first — bridges resume when Scarf's own
    /// conversation identity is empty. Defaults to
    /// ``SessionAttributionService/recentSessionIDs(forProject:)`` when
    /// `serverContext` is set, else an empty list.
    typealias FallbackSessionIDsLoader = () -> [String]
    /// Records that a newly (re)started Hermes session id belongs to this
    /// project path, mirroring legacy `ChatView` attribution so Sessions /
    /// resume continue to find it. Defaults to
    /// ``SessionAttributionService/attribute(sessionID:toProjectPath:)``
    /// when `serverContext` is set, else a no-op.
    typealias SessionAttributor = (String, String) -> Void

    private let controller: AgentConversationController
    private let backendID: AgentID
    private let workingDirectory: URL
    private let baseSlashRegistry: AgentSlashCommandRegistry
    private var slashHintPresenter: AgentSlashHintPresenter
    private let extensionCatalogLoader: ExtensionCatalogLoader
    private let modelsLoader: ModelsLoader
    /// Window/profile context for Hermes-only boot steps (attribution,
    /// project model preset, capability probing). `nil` keeps every one of
    /// those steps a no-op — never a guessed local/default context.
    let serverContext: ServerContext?
    /// Stable project identity for attribution + the auto-accept-edits store.
    /// Defaults to `workingDirectory.path` when not given explicitly.
    let projectPath: String
    private let fallbackSessionIDsLoader: FallbackSessionIDsLoader
    private let sessionAttributor: SessionAttributor
    private let authHealthLoader: AuthHealthLoader
    private let autoAcceptStore: ProjectAutoAcceptEditsStore
    private let capabilitiesLoader: CapabilitiesLoader
    private let projectPresetApplier: ProjectPresetApplier?

    private(set) var state = AgentConversationState()
    private(set) var isStarted = false
    private(set) var startupError: String?
    /// Mirrored from the controller after start/restore for sync VoiceTurnHost.
    private(set) var activeSessionID: String?

    /// Per-session edit auto-approval mode. Hermes-only: `.default` on
    /// Claude (no menu is shown there). Flipped optimistically by
    /// ``selectApprovalMode(_:)`` and by the boot auto-accept-edits step.
    private(set) var activeApprovalMode: ACPApprovalMode = .default

    /// `true` when a verified Hermes credential probe found none at boot.
    /// Recoverable — the session still starts (mirrors legacy `ChatView`'s
    /// `missingCredentials` banner, which never blocked sending).
    private(set) var missingCredentialsBanner = false

    /// One-line notice when a typed idle `/queue` or `/steer` ran as an
    /// ordinary prompt instead of its interruptive-looking affordance.
    /// Cleared at the start of every `send(_:)`.
    private(set) var idleSlashNotice: String?

    /// Short-lived composer/header hint (queue success, Live Voice refusal).
    private(set) var transientHint: String?

    /// Optimistic `/queue` mirror for the header chip (Hermes v0.13+).
    private(set) var queuedPrompts: [HermesQueuedPrompt] = []

    /// Whether the composer should offer image attachments (Hermes +
    /// `hasACPImagePrompts`). Refreshed at start / capability load.
    private(set) var supportsImageAttachments = false

    /// Claude-only restore notice: Claude returns no structured history, so
    /// Scarf durable transcript (or an empty chat) is what the user sees.
    /// Nil for Hermes and for Claude before the first successful start.
    private(set) var historyRestoreNotice: String?

    /// Most recent non-fatal action failure (model switch, approval-mode
    /// switch) for UI surfacing beyond ``AgentConversationState/error``,
    /// which only covers controller-originated failures.
    private(set) var lastActionError: String?

    /// Live Voice session for this AgentChat surface (Hermes-only).
    let voiceLive = VoiceLiveController()

    /// Raw `voice.voice_chat_mode` from the window ChatViewModel / config.
    /// Set by the view before starting Live Voice.
    var voiceChatModeRaw: String?

    @ObservationIgnored
    private var wasAgentRunning = false
    @ObservationIgnored
    private var voiceTurnPrompts: [(id: String, prompt: String)] = []
    @ObservationIgnored
    private var busyVoiceRequestIDs: [String] = []
    @ObservationIgnored
    private var hintClearTask: Task<Void, Never>?

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
        modelsLoader: ModelsLoader? = nil,
        serverContext: ServerContext? = nil,
        projectPath: String? = nil,
        fallbackSessionIDsLoader: FallbackSessionIDsLoader? = nil,
        sessionAttributor: SessionAttributor? = nil,
        authHealthLoader: AuthHealthLoader? = nil,
        autoAcceptStore: ProjectAutoAcceptEditsStore = ProjectAutoAcceptEditsStore(),
        capabilitiesLoader: CapabilitiesLoader? = nil,
        projectPresetApplier: ProjectPresetApplier? = nil
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

        self.serverContext = serverContext
        let resolvedProjectPath = projectPath ?? workingDirectory.path
        self.projectPath = resolvedProjectPath

        if let fallbackSessionIDsLoader {
            self.fallbackSessionIDsLoader = fallbackSessionIDsLoader
        } else if let serverContext {
            self.fallbackSessionIDsLoader = {
                SessionAttributionService(context: serverContext)
                    .recentSessionIDs(forProject: resolvedProjectPath)
            }
        } else {
            self.fallbackSessionIDsLoader = { [] }
        }

        if let sessionAttributor {
            self.sessionAttributor = sessionAttributor
        } else if let serverContext {
            self.sessionAttributor = { sessionID, path in
                SessionAttributionService(context: serverContext)
                    .attribute(sessionID: sessionID, toProjectPath: path)
            }
        } else {
            self.sessionAttributor = { _, _ in }
        }

        self.authHealthLoader = authHealthLoader ?? { .notProbed }
        self.autoAcceptStore = autoAcceptStore
        self.capabilitiesLoader = capabilitiesLoader ?? { .empty }
        self.projectPresetApplier = projectPresetApplier

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

    /// Claude always exposes a launch-time model menu. Hermes exposes the
    /// picker API when catalog models are non-empty (live ACP `set_model`).
    var supportsModelPicker: Bool {
        switch backendID {
        case .claudeCode:
            return true
        case .hermes:
            return !availableModels.isEmpty
        default:
            return false
        }
    }

    func start() async {
        guard !isStarted else { return }
        startupError = nil
        historyRestoreNotice = nil

        // Recoverable preflight, mirrors legacy `ChatView`'s
        // `missingCredentials` banner: a probe that finds nothing still lets
        // the session start — credentials can be fixed from a running chat.
        if backendID == .hermes {
            let health = await authHealthLoader()
            missingCredentialsBanner = (health == .noCredentialsDetected)
        }

        // Bridges Hermes ChatView attributions when Scarf's own conversation
        // identity (keyed by `project.id`) is empty — a project chatted in
        // before this surface existed still resumes instead of starting over.
        let fallbackSessionIDs = backendID == .hermes ? fallbackSessionIDsLoader() : []

        do {
            let session = try await controller.startOrRestorePersistedSession(
                backendID: backendID,
                configuration: AgentSessionConfiguration(
                    workingDirectory: workingDirectory,
                    modelID: selectedModelID
                ),
                fallbackSessionIDs: fallbackSessionIDs
            )
            isStarted = true
            activeSessionID = session.id

            if backendID == .hermes {
                sessionAttributor(session.id, projectPath)
                await applyProjectModelPresetIfNeeded()
                await applyAutoAcceptEditsIfNeeded()
            }

            if backendID == .claudeCode {
                historyRestoreNotice = Self.claudeHistoryRestoreNotice(
                    messageCount: state.messages.count
                )
                await loadExtensionsCatalog()
            }

            if backendID == .hermes {
                let capabilities = await capabilitiesLoader()
                supportsImageAttachments = capabilities.hasACPImagePrompts
            } else {
                supportsImageAttachments = false
            }

            await refreshAvailableModels()
        } catch {
            startupError = Self.userFacingErrorMessage(error)
        }
    }

    /// Retry a failed start (install/auth/process). No-op when already started.
    func retryStart() async {
        guard !isStarted else { return }
        await start()
    }

    /// Clear a non-fatal action error the user has dismissed.
    func dismissLastActionError() {
        lastActionError = nil
    }

    /// Claude has no structured history API — explain Scarf-preferring restore.
    static func claudeHistoryRestoreNotice(messageCount: Int) -> String {
        if messageCount > 0 {
            return "Showing Scarf's saved transcript. Claude Code does not expose structured session history yet — Scarf never scrapes Claude's session files."
        }
        return "No prior Scarf transcript for this conversation. Claude Code does not expose structured session history yet."
    }

    /// Prefer `AgentError.message` over Swift's noisy `Error` dump.
    static func userFacingErrorMessage(_ error: Error) -> String {
        if let agentError = error as? AgentError {
            switch agentError.code {
            case "claude.not-installed":
                return "Claude Code CLI not found. Install the Claude CLI, then run `claude login` in Terminal. Scarf does not manage Claude's sign-in."
            default:
                return agentError.message
            }
        }
        return String(describing: error)
    }

    /// Resolve and apply this project's bound model preset to the fresh
    /// Hermes session (non-fatal — mirrors `ChatViewModel`'s
    /// `applyProjectModelPreset` / `ProjectModelPresetApplier`, but through
    /// the backend-neutral controller instead of a raw `ACPClient`).
    private func applyProjectModelPresetIfNeeded() async {
        let outcome: AgentProjectPresetOutcome
        if let projectPresetApplier {
            outcome = await projectPresetApplier(projectPath)
        } else {
            outcome = await Self.defaultProjectModelPresetApplier(
                controller: controller,
                projectPath: projectPath,
                context: serverContext
            )
        }
        if case .applied(let preset) = outcome {
            selectedModelID = Self.pickerID(for: preset)
        }
    }

    /// Production implementation of the preset-apply seam. A `static` method
    /// (no `self` capture) so the test seam can call the exact same
    /// disk/network-free logic as `AgentChatViewModelProductionParityTests`.
    /// No binding, a deleted preset, an unreadable store, or a host that
    /// rejects `session/set_model` all leave the session on the config.yaml
    /// default — only `.applied` changes `selectedModelID`.
    private static func defaultProjectModelPresetApplier(
        controller: AgentConversationController,
        projectPath: String,
        context: ServerContext?
    ) async -> AgentProjectPresetOutcome {
        guard let context else { return .noBinding }
        let idString = await OffPool.run {
            ProjectModelPresetReader(context: context).presetID(forProjectPath: projectPath)
        }
        guard let idString, let presetID = UUID(uuidString: idString) else {
            return .noBinding
        }
        let preset: ModelPreset?
        do {
            preset = try await ModelPresetService.shared(for: context).get(id: presetID)
        } catch {
            return .storeUnreadable(message: String(describing: error))
        }
        guard let preset else { return .presetMissing(id: idString) }
        do {
            try await controller.setSessionModel(
                modelID: preset.modelID,
                providerID: preset.providerID.isEmpty ? nil : preset.providerID
            )
            return .applied(preset)
        } catch {
            return .rejected(preset, message: String(describing: error))
        }
    }

    /// The model picker id (`provider:model`, matching `AgentModelPickerID`'s
    /// catalog shape) a preset resolves to.
    private static func pickerID(for preset: ModelPreset) -> String {
        preset.providerID.isEmpty ? preset.modelID : "\(preset.providerID):\(preset.modelID)"
    }

    /// Open this Hermes session in `accept_edits` once at boot when the user
    /// has turned auto-accept on for the project AND the host advertises
    /// `session/set_mode` (mirrors `ChatViewModel.applyProjectAutoAcceptEdits`).
    /// Non-fatal: a pre-v0.15 host or an RPC failure leaves the session on
    /// `.default` — the controller already surfaced any RPC failure on
    /// `state.error`.
    private func applyAutoAcceptEditsIfNeeded() async {
        guard autoAcceptStore.isEnabled(projectId: projectPath) else { return }
        let capabilities = await capabilitiesLoader()
        guard capabilities.hasSessionEditAutoApproval else { return }
        do {
            try await controller.setSessionMode(modeID: ACPApprovalMode.acceptEdits.rawValue)
            activeApprovalMode = .acceptEdits
        } catch {
            // Non-fatal — session stays on the default ask-first mode.
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

    /// Claude: close and recreate the session with `--model`.
    /// Hermes: live ACP `session/set_model` (no restart); revert on failure.
    /// Same id is a no-op. Ignored while a turn is running or a switch is in flight.
    func selectModel(id: String) async {
        guard supportsModelPicker else { return }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedModelID else { return }
        guard !isChangingModel, !state.isRunning else { return }

        isChangingModel = true
        defer { isChangingModel = false }

        switch backendID {
        case .claudeCode:
            // Claude has no VM-level mirror: a restart failure already lands
            // on `startupError`, which the transcript renders directly.
            selectedModelID = trimmed
            await close()
            await start()
        case .hermes:
            let previous = selectedModelID
            selectedModelID = trimmed
            let parts = AgentModelPickerID.split(trimmed)
            do {
                try await controller.setSessionModel(
                    modelID: parts.modelID,
                    providerID: parts.providerID
                )
                lastActionError = nil
            } catch {
                // The controller already surfaced the failure on
                // `state.error`; mirror it here too so a VM-level consumer
                // doesn't have to know which state object a given backend
                // reports failures on.
                selectedModelID = previous
                lastActionError = Self.userFacingErrorMessage(error)
            }
        default:
            return
        }
    }

    /// Live mid-session approval-mode switch (Hermes ACP `session/set_mode`,
    /// v0.15+). Optimistic — the UI flips immediately and only reverts on
    /// RPC failure, mirroring `selectModel`'s Hermes branch and
    /// `ChatViewModel.switchApprovalMode`. Claude has no such RPC and ignores
    /// this call. Same mode is a no-op.
    func selectApprovalMode(_ mode: ACPApprovalMode) async {
        guard backendID == .hermes, isStarted else { return }
        guard activeApprovalMode != mode else { return }

        let previous = activeApprovalMode
        activeApprovalMode = mode
        do {
            try await controller.setSessionMode(modeID: mode.rawValue)
            lastActionError = nil
        } catch {
            activeApprovalMode = previous
            lastActionError = Self.userFacingErrorMessage(error)
        }
    }

    /// Help text for the model menu — Claude restarts; Hermes switches live.
    var modelPickerHelp: String {
        switch backendID {
        case .hermes:
            return "Switch the Hermes session model via ACP (live)"
        default:
            return "Restart this Claude session with the selected model"
        }
    }

    /// Badge / menu label. Selected model wins; otherwise a single
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
        try await send(content, images: [])
    }

    func send(_ content: String, images: [ChatImageAttachment]) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        idleSlashNotice = nil

        // Claude has none of Hermes's ACP `/queue` & `/steer` idle-rewrite
        // semantics — the typed text goes through verbatim, as before.
        guard backendID == .hermes else {
            try await controller.send(trimmed.isEmpty ? " " : trimmed, images: images)
            return
        }

        // Snapshot BEFORE the send — `controller.send` immediately flips
        // `state.isRunning` via `beginUserTurn`, so reading it after would
        // make every turn look like it started mid-turn.
        let isAgentWorking = state.isRunning
        let parsed = RichChatViewModel.parseSlashName(trimmed)
        let capabilities = await capabilitiesLoader()
        supportsImageAttachments = capabilities.hasACPImagePrompts

        // A typed `/queue <text>` with nothing running is not a queue on
        // Hermes's side: the adapter appends it and returns `end_turn`
        // before the only drain (a turn that's already running). Send the
        // argument as an ordinary prompt instead — leaving the `/queue`
        // prefix on the wire would hand it straight back to `_cmd_queue`
        // and make the notice a lie.
        let idleQueueText = RichChatViewModel.idleQueueFallbackText(
            name: parsed.name,
            args: parsed.args,
            isAgentWorking: isAgentWorking,
            capabilities: capabilities
        )
        // A typed `/steer <text>` with nothing running is an ordinary turn
        // on Hermes's side too — the adapter strips the prefix before slash
        // dispatch ever sees it. The wire text needs no change there; only
        // the notice does.
        let idleSteer = RichChatViewModel.idleSteerIsOrdinaryPrompt(
            name: parsed.name,
            args: parsed.args,
            isAgentWorking: isAgentWorking,
            capabilities: capabilities
        )

        if idleQueueText != nil {
            idleSlashNotice = RichChatViewModel.idleQueueNotice
        } else if idleSteer {
            idleSlashNotice = RichChatViewModel.idleSteerNotice
        } else if let subFloorNotice = RichChatViewModel.subFloorSlashNotice(
            name: parsed.name,
            capabilities: capabilities
        ) {
            idleSlashNotice = subFloorNotice
        }

        let wireText = idleQueueText ?? (trimmed.isEmpty ? " " : trimmed)

        // Mid-turn `/queue` mirror (optimistic header chip).
        if isAgentWorking,
           parsed.name == "queue",
           idleQueueText == nil,
           capabilities.hasACPQueue {
            let queuedText = parsed.args.trimmingCharacters(in: .whitespacesAndNewlines)
            if !queuedText.isEmpty {
                queuedPrompts.append(HermesQueuedPrompt(text: queuedText))
                transientHint = "Queued — runs after current turn."
                scheduleHintClear()
            }
        } else if isAgentWorking,
                  parsed.name == "steer",
                  !idleSteer,
                  capabilities.hasACPSteer {
            transientHint = "Guidance queued — applies after the next tool call."
            scheduleHintClear()
        }

        try await controller.send(wireText, images: images)
    }

    func sendDraft(images: [ChatImageAttachment] = []) async throws {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !images.isEmpty else { return }
        draft = ""
        try await send(message, images: images)
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
        leaveVoiceLive()
        guard isStarted else { return }
        do {
            try await controller.close()
        } catch {
            // Teardown is best effort. The backend process/channel owns its own
            // bounded shutdown path, and leaving Chat must not trap the user on
            // the surface because a close notification failed.
        }
        isStarted = false
        activeSessionID = nil
        queuedPrompts = []
    }

    func respond(to request: AgentPermissionRequest, optionID: String) async throws {
        try await controller.respond(to: request, optionID: optionID)
    }

    func cancelPermission(_ request: AgentPermissionRequest) async throws {
        try await controller.cancelPermission(request)
    }

    // MARK: - Live Voice (Hermes)

    var canHostVoiceTurns: Bool {
        backendID == .hermes && isStarted && serverContext != nil
    }

    func voiceLiveAvailability(capabilities: HermesCapabilities) -> VoiceLiveAvailability {
        VoiceLiveReadiness.availability(capabilities: capabilities, voiceChatMode: voiceChatModeRaw)
    }

    func startVoiceLive(capabilities: HermesCapabilities) {
        guard backendID == .hermes, isStarted, let context = serverContext else { return }
        guard canHostVoiceTurns else { return }
        guard let engineKind = voiceLiveAvailability(capabilities: capabilities).engineKind else { return }
        voiceLive.start(context: context, host: self, engineKind: engineKind)
        if voiceLive.consumeStartRefusal() == .blockedByAnotherWindow {
            transientHint = String(
                localized: "Live Voice is running in another Scarf window. End it there first."
            )
            scheduleHintClear()
        }
    }

    func leaveVoiceLive() {
        voiceLive.dismiss()
    }

    func acceptVoiceLiveConsent(capabilities: HermesCapabilities) {
        guard voiceLive.pendingConsent != nil else { return }
        voiceLive.acceptConsent()
        startVoiceLive(capabilities: capabilities)
    }

    private func scheduleHintClear() {
        hintClearTask?.cancel()
        hintClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientHint = nil
        }
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
                guard let self else { break }
                let wasRunning = self.wasAgentRunning
                self.state = snapshot
                self.wasAgentRunning = snapshot.isRunning
                if wasRunning, !snapshot.isRunning {
                    self.queuedPrompts = []
                }
                self.applyDiscoveredSlashCommands(from: snapshot)
                self.refreshDiscoveryAfterClaudeHandshake(from: snapshot)
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

// MARK: - VoiceTurnHost

extension AgentChatViewModel: VoiceTurnHost {
    enum VoiceTurnSubmitError: Error, Equatable {
        case noSession
    }

    var isVoiceTurnBusy: Bool { state.isRunning }

    var activeVoiceToolName: String? {
        state.toolCalls.first(where: { $0.status == .running })?.title
    }

    var voiceChatID: String? { activeSessionID }

    var isBusyWithNonVoiceTurn: Bool {
        // AgentChat has no separate typed/voice origin ledger — any running
        // turn blocks a new spoken submit the same way.
        state.isRunning
    }

    static let voiceBusyReply =
        "Hermes is busy with another request in this chat, so I didn't send that. Ask me again when it's finished."

    func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {
        guard canHostVoiceTurns else { throw VoiceTurnSubmitError.noSession }
        if state.isRunning {
            busyVoiceRequestIDs.append(request.id)
            if busyVoiceRequestIDs.count > 8 {
                busyVoiceRequestIDs.removeFirst(busyVoiceRequestIDs.count - 8)
            }
            transientHint = String(
                localized: "Live Voice didn't interrupt your typed request. Ask again when it's finished."
            )
            scheduleHintClear()
            return
        }
        voiceTurnPrompts.append((id: request.id, prompt: request.prompt))
        if voiceTurnPrompts.count > 8 {
            voiceTurnPrompts.removeFirst(voiceTurnPrompts.count - 8)
        }
        try await controller.send(
            request.prompt,
            images: [],
            contextNotes: request.contextNotes
        )
    }

    func cancelActiveVoiceTurn() async {
        guard state.isRunning else { return }
        try? await controller.cancel()
    }

    func voiceTurnReply(for requestID: String) -> VoiceTurnReply? {
        if busyVoiceRequestIDs.contains(requestID) {
            return VoiceTurnReply(text: Self.voiceBusyReply, isStreaming: false)
        }
        guard let prompt = voiceTurnPrompts.last(where: { $0.id == requestID })?.prompt else {
            return nil
        }
        let wanted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let userIndex = state.messages.lastIndex(where: {
            $0.role == .user
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }) else {
            return nil
        }
        let after = state.messages.suffix(from: state.messages.index(after: userIndex))
        let assistant = after.last(where: { $0.role == .assistant })?.content ?? ""
        let draft = state.assistantDraft
        let text = draft.isEmpty ? assistant : draft
        guard !text.isEmpty else { return nil }
        return VoiceTurnReply(text: text, isStreaming: state.isRunning && !draft.isEmpty)
    }

    func voiceSeedTurns() -> [VoiceLiveText.SeedTurn] {
        state.messages.compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user: return VoiceLiveText.SeedTurn(role: .user, text: text)
            case .assistant: return VoiceLiveText.SeedTurn(role: .assistant, text: text)
            default: return nil
            }
        }
    }
}
