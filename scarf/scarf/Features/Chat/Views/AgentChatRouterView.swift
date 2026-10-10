import SwiftUI
import UniformTypeIdentifiers
import ScarfCore
import ScarfDesign

/// Strangler router for Chat.
///
/// Plain Chat and Hermes projects with the AgentChat flag off still render
/// the original `ChatView`. Hermes projects with
/// `scarf.experimental.hermesAgentChat` on (default), and projects that prefer
/// a non-Hermes backend, reach the generic surface.
struct AgentChatRouterView: View {
    let viewModel: AgentChatRouterViewModel

    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Group {
            if let pendingPath = coordinator.pendingProjectChat {
                routedContent(for: pendingPath)
                    .task(id: pendingPath) {
                        await viewModel.resolve(projectPath: pendingPath)
                    }
            } else {
                currentContent
            }
        }
    }

    @ViewBuilder
    private func routedContent(for projectPath: String) -> some View {
        switch viewModel.route {
        case .legacy(let resolvedPath) where resolvedPath == projectPath:
            // Preserve the original consumer exactly. It clears the project
            // handoff and handles the optional initial prompt itself.
            ChatView()

        case .agent(let project, let agentViewModel) where project.rootPath == projectPath:
            AgentProjectChatView(project: project, viewModel: agentViewModel)

        case .unavailable(let resolvedPath, let backendID, let message)
            where resolvedPath == projectPath:
            AgentBackendUnavailableView(
                projectPath: projectPath,
                backendID: backendID,
                message: message
            )

        default:
            AgentRouteResolvingView(projectPath: projectPath)
        }
    }

    @ViewBuilder
    private var currentContent: some View {
        switch viewModel.route {
        case .agent(let project, let agentViewModel):
            AgentProjectChatView(project: project, viewModel: agentViewModel)

        case .unavailable(let projectPath, let backendID, let message):
            AgentBackendUnavailableView(
                projectPath: projectPath,
                backendID: backendID,
                message: message
            )

        case .legacy, .resolving:
            ChatView()
        }
    }
}

private struct AgentRouteResolvingView: View {
    let projectPath: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Selecting chat backend…")
                .font(.headline)
            Text(projectPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct AgentBackendUnavailableView: View {
    let projectPath: String
    let backendID: AgentID?
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Agent Backend Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                if let backendID {
                    Text("This project is configured for \(backendID.rawValue).")
                }
                Text(message)
                // Claude Code owns its own CLI login state — Scarf never
                // manages its OAuth flow or reads its Keychain item, so the
                // only actionable guidance here is the CLI itself.
                if backendID == .claudeCode {
                    Text("Install the Claude CLI, then run `claude login` in Terminal to authenticate. Scarf does not manage Claude's sign-in — the CLI owns its own login state.")
                        .foregroundStyle(.secondary)
                }
                Text(projectPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }
}

/// First generic project-chat surface. The presentation is intentionally small:
/// the important milestone is proving the backend-neutral lifecycle and Claude
/// stream end-to-end before porting Hermes' richer chat affordances.
private struct AgentProjectChatView: View {
    let project: ScarfProject
    @Bindable var viewModel: AgentChatViewModel

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ChatViewModel.self) private var chatViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @AppStorage(ChatDensityKeys.toolCardStyle)
    private var toolCardStyleRaw: String = ToolCardStyle.full.rawValue
    @AppStorage(ChatDensityKeys.reasoningStyle)
    private var reasoningStyleRaw: String = ReasoningStyle.disclosure.rawValue
    @AppStorage(ChatDensityKeys.fontScale)
    private var chatFontScale: Double = ChatFontScale.default
    @State private var selectedSlashHintIndex = 0
    @State private var isExtensionsSheetPresented = false
    @State private var attachmentSlots = ComposerAttachmentSlots()
    @State private var attachmentError: String?
    @State private var isImportingImages = false

    private var toolCardStyle: ToolCardStyle {
        ToolCardStyle(rawValue: toolCardStyleRaw) ?? .full
    }

    private var reasoningStyle: ReasoningStyle {
        ReasoningStyle(rawValue: reasoningStyleRaw) ?? .disclosure
    }

    /// Hermes AgentChat can host the window `ChatViewModel` SwiftTerm.
    /// Claude has no Hermes TUI path.
    private var supportsTerminalMode: Bool {
        project.preferredAgentID == .hermes
    }

    private var isTerminalMode: Bool {
        supportsTerminalMode && chatViewModel.displayMode == .terminal
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isTerminalMode {
                agentTerminalArea
            } else {
                ZStack {
                    // Keep Hermes TTY alive when toggling back to AgentChat
                    // (same pattern as ChatView.richChatArea).
                    if supportsTerminalMode, let terminal = chatViewModel.terminalView {
                        PersistentTerminalView(terminalView: terminal)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 0) {
                        transcript
                        Divider()
                        composer
                    }
                }
            }
        }
        .dynamicTypeSize(ChatFontScale.dynamicTypeSize(for: chatFontScale))
        .task(id: project.rootPath) {
            viewModel.voiceChatModeRaw = chatViewModel.voiceChatModeRaw
            await startAndConsumeHandoff()
        }
        .onChange(of: chatViewModel.voiceChatModeRaw) { _, mode in
            viewModel.voiceChatModeRaw = mode
        }
        .onDisappear {
            viewModel.leaveVoiceLive()
            Task { await viewModel.close() }
        }
        .sheet(item: Binding(
            get: { viewModel.voiceLive.pendingConsent },
            set: { if $0 == nil { viewModel.voiceLive.declineConsent() } }
        )) { recipient in
            VoiceLiveConsentSheet(
                recipient: recipient,
                mode: .ask(
                    onContinue: {
                        viewModel.acceptVoiceLiveConsent(
                            capabilities: capabilitiesStore?.capabilities ?? .empty
                        )
                    },
                    onCancel: { viewModel.voiceLive.declineConsent() }
                )
            )
        }
        .onChange(of: chatViewModel.displayMode) { _, mode in
            guard supportsTerminalMode else { return }
            if mode == .terminal {
                // Mutual exclusion: Terminal launch stops ACP on ChatViewModel;
                // also tear down AgentChat's own controller session.
                Task { await viewModel.close() }
            } else if !viewModel.isStarted {
                Task { await viewModel.start() }
            }
        }
        .onChange(of: viewModel.slashHintPresentation.query) { _, _ in
            selectedSlashHintIndex = 0
        }
        .onChange(of: viewModel.slashHints.count) { _, count in
            if selectedSlashHintIndex >= count {
                selectedSlashHintIndex = max(0, count - 1)
            }
        }
        .sheet(isPresented: $isExtensionsSheetPresented) {
            AgentExtensionsBrowserSheet(
                presentation: viewModel.extensionBrowserPresentation,
                isLoading: viewModel.isLoadingExtensions,
                onDismiss: { isExtensionsSheetPresented = false }
            )
            .task {
                await viewModel.loadExtensionsCatalog()
            }
        }
    }

    @ViewBuilder
    private var agentTerminalArea: some View {
        if let terminal = chatViewModel.terminalView {
            PersistentTerminalView(terminalView: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if chatViewModel.hermesBinaryExists {
            ContentUnavailableView(
                "No Active Session",
                systemImage: "terminal",
                description: Text("Start or continue a Hermes TTY session from the Session menu. Terminal mode stops the AgentChat ACP session for this window.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Hermes Not Found",
                systemImage: "terminal",
                description: Text("Expected at \(chatViewModel.context.paths.hermesBinary)")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isTerminalMode ? "terminal" : "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                Text("\(backendDisplayName) · \(project.rootPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !viewModel.queuedPrompts.isEmpty {
                ChatQueueIndicator(queuedPrompts: viewModel.queuedPrompts)
            }

            if supportsTerminalMode {
                Picker("View", selection: Bindable(chatViewModel).displayMode) {
                    Image(systemName: "terminal")
                        .help("Terminal — Hermes TTY; stops AgentChat ACP for this window")
                        .tag(ChatDisplayMode.terminal)
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .help("AgentChat")
                        .tag(ChatDisplayMode.richChat)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Chat display mode")

                if isTerminalMode {
                    Menu {
                        Button("New Terminal Session") {
                            chatViewModel.startNewSession(projectPath: project.rootPath)
                        }
                        Button("Continue Last Session") {
                            chatViewModel.continueLastSession()
                        }
                    } label: {
                        Label("Session", systemImage: "play.circle")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Hermes TTY session. Switching to Terminal stops the AgentChat ACP session.")
                }
            }

            if !isTerminalMode, viewModel.supportsModelPicker, !viewModel.availableModels.isEmpty {
                Menu {
                    ForEach(viewModel.availableModels) { model in
                        Button {
                            Task { await viewModel.selectModel(id: model.id) }
                        } label: {
                            if viewModel.selectedModelID == model.id {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                } label: {
                    Text(viewModel.modelBadgeLabel ?? "Model")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .padding(.horizontal, ScarfSpace.s2)
                        .padding(.vertical, ScarfSpace.s1)
                        .background(ScarfColor.backgroundSecondary, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .disabled(
                    viewModel.isChangingModel
                        || viewModel.isLoadingModels
                        || viewModel.state.isRunning
                )
                .help(viewModel.modelPickerHelp)
                .accessibilityLabel("Model: \(viewModel.modelBadgeLabel ?? "default")")
            } else if !isTerminalMode, let modelLabel = viewModel.modelBadgeLabel {
                Text(modelLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .padding(.horizontal, ScarfSpace.s2)
                    .padding(.vertical, ScarfSpace.s1)
                    .background(ScarfColor.backgroundSecondary, in: Capsule())
                    .help("Models advertised by this backend (read-only)")
                    .accessibilityLabel("Models: \(modelLabel)")
            } else if !isTerminalMode, viewModel.isLoadingModels {
                ProgressView()
                    .controlSize(.mini)
            }

            // Hermes-only: Claude Code has no `session/set_mode` RPC, so the
            // picker never renders there. Shown unconditionally for Hermes
            // (rather than gated behind a live capability check) so the user
            // always has an explanation — `selectApprovalMode` itself is a
            // safe no-op on a host that can't honor it.
            if !isTerminalMode, project.preferredAgentID == .hermes, viewModel.isStarted {
                ChatApprovalModeBadge(mode: viewModel.activeApprovalMode) { mode in
                    Task { await viewModel.selectApprovalMode(mode) }
                }
            }

            if !isTerminalMode {
                Button {
                    isExtensionsSheetPresented = true
                } label: {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoadingExtensions)
                .help("Browse this backend's extension catalog (read-only)")

                if viewModel.state.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Stop") {
                        Task { try? await viewModel.cancel() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if viewModel.missingCredentialsBanner {
                    AgentInlineBanner(
                        icon: "key.fill",
                        title: "No AI provider credentials detected",
                        message: "Add credentials in Configure → Credential Pools, set ANTHROPIC_API_KEY (or similar) in ~/.hermes/.env, or export it in your shell profile, then restart Scarf."
                    )
                }

                if let historyNotice = viewModel.historyRestoreNotice {
                    AgentInlineBanner(
                        icon: "clock.arrow.circlepath",
                        title: "Conversation restore",
                        message: historyNotice
                    )
                }

                if let startupError = viewModel.startupError {
                    AgentInlineError(
                        title: "Could not start \(backendDisplayName)",
                        message: startupError,
                        retryTitle: "Retry",
                        onRetry: { Task { await viewModel.retryStart() } }
                    )
                }

                if let error = viewModel.state.error {
                    AgentInlineError(title: "Agent error", message: error.message)
                }

                if let lastActionError = viewModel.lastActionError {
                    AgentInlineError(
                        title: "Action failed",
                        message: lastActionError,
                        retryTitle: "Dismiss",
                        onRetry: { viewModel.dismissLastActionError() }
                    )
                }

                if let idleSlashNotice = viewModel.idleSlashNotice {
                    AgentInlineBanner(icon: "info.circle", title: nil, message: idleSlashNotice)
                }

                if let transientHint = viewModel.transientHint {
                    AgentInlineBanner(icon: "info.circle", title: nil, message: transientHint)
                }

                if viewModel.isStarted,
                   viewModel.state.messages.isEmpty,
                   viewModel.state.assistantDraft.isEmpty,
                   viewModel.startupError == nil {
                    ContentUnavailableView {
                        Label("Ready", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Send a message to start chatting with \(backendDisplayName).")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                if let plan = AgentPlanCalloutPresenter.planText(from: viewModel.state) {
                    VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                        Label("Plan", systemImage: "list.bullet.rectangle")
                            .scarfStyle(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(ScarfColor.accent)
                        Text(plan)
                            .font(ScarfFont.mono)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(ScarfSpace.s3)
                    .background(ScarfColor.backgroundSecondary, in: RoundedRectangle(cornerRadius: ScarfRadius.xl))
                    .overlay(
                        RoundedRectangle(cornerRadius: ScarfRadius.xl)
                            .strokeBorder(ScarfColor.borderStrong, lineWidth: 0.5)
                    )
                }

                ForEach(viewModel.state.messages) { message in
                    AgentMessageRow(message: message)
                }

                if !viewModel.state.reasoningDraft.isEmpty, reasoningStyle != .hidden {
                    AgentReasoningDraftView(
                        text: viewModel.state.reasoningDraft,
                        style: reasoningStyle
                    )
                }

                if !viewModel.state.assistantDraft.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assistant")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.state.assistantDraft)
                            .font(ChatFontScale.body(chatFontScale))
                            .textSelection(.enabled)
                    }
                }

                if toolCardStyle != .hidden,
                   !viewModel.state.toolCalls.isEmpty
                    || !viewModel.state.commands.isEmpty
                    || !viewModel.state.fileChanges.isEmpty
                    || viewModel.state.usage != nil {
                    AgentActivitySummary(
                        state: viewModel.state,
                        toolStyle: toolCardStyle
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var voiceCapabilities: HermesCapabilities {
        capabilitiesStore?.capabilities ?? .empty
    }

    private var voiceLiveEntry: VoiceLiveComposerEntry? {
        guard project.preferredAgentID == .hermes else { return nil }
        let availability = viewModel.voiceLiveAvailability(capabilities: voiceCapabilities)
        guard let engineKind = availability.engineKind else { return nil }
        return VoiceLiveComposerEntry(
            engineKind: engineKind,
            isActive: viewModel.voiceLive.engine != nil,
            canStart: viewModel.canHostVoiceTurns,
            blockedByAnotherWindow: VoiceLiveSessionRegistry.shared.isAnySessionActive
                && viewModel.voiceLive.engine == nil,
            onToggle: {
                if viewModel.voiceLive.engine != nil {
                    viewModel.leaveVoiceLive()
                } else {
                    viewModel.startVoiceLive(capabilities: voiceCapabilities)
                }
            }
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.voiceLive.engine != nil || viewModel.voiceLive.startFailure != nil {
                VoiceLivePanel(
                    controller: viewModel.voiceLive,
                    onRestart: { viewModel.startVoiceLive(capabilities: voiceCapabilities) },
                    ttsProvider: chatViewModel.voiceTTSProviderRaw,
                    canRestart: viewModel.canHostVoiceTurns
                )
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.top, ScarfSpace.s2)
            }

            if let permission = viewModel.permissionPresentation {
                AgentPermissionCard(
                    presentation: permission,
                    onRespond: { request, optionID in
                        Task { try? await viewModel.respond(to: request, optionID: optionID) }
                    },
                    onCancel: { request in
                        Task { try? await viewModel.cancelPermission(request) }
                    }
                )
                .id(permission.id)
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.top, ScarfSpace.s2)
            }

            if viewModel.isSlashHintMenuVisible {
                AgentSlashHintMenu(
                    presentation: viewModel.slashHintPresentation,
                    selectedIndex: $selectedSlashHintIndex,
                    onSelect: { hint in
                        viewModel.acceptSlashHint(hint)
                    }
                )
                .id(viewModel.slashHintPresentation.query)
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.top, ScarfSpace.s2)
            }

            if viewModel.supportsImageAttachments,
               !attachmentSlots.attachments.isEmpty || attachmentSlots.isEncoding || attachmentError != nil {
                agentAttachmentStrip
                    .padding(.horizontal, ScarfSpace.s3)
                    .padding(.top, ScarfSpace.s2)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if viewModel.supportsImageAttachments {
                    Button {
                        isImportingImages = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.isStarted || attachmentSlots.isFull)
                    .help("Attach image (\(attachmentSlots.attachments.count)/\(ComposerAttachmentSlots.defaultCapacity))")
                    .fileImporter(
                        isPresented: $isImportingImages,
                        allowedContentTypes: [.image],
                        allowsMultipleSelection: true
                    ) { result in
                        handleImageImport(result)
                    }
                }

                TextField(
                    "Message \(backendDisplayName)…",
                    text: $viewModel.draft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit { submitComposer() }
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    guard viewModel.supportsImageAttachments else { return false }
                    ingestImageProviders(providers)
                    return true
                }
                .onKeyPress(.upArrow, phases: .down) { _ in
                    guard viewModel.isSlashHintMenuVisible, !viewModel.slashHints.isEmpty else {
                        return .ignored
                    }
                    selectedSlashHintIndex = max(0, selectedSlashHintIndex - 1)
                    return .handled
                }
                .onKeyPress(.downArrow, phases: .down) { _ in
                    guard viewModel.isSlashHintMenuVisible, !viewModel.slashHints.isEmpty else {
                        return .ignored
                    }
                    selectedSlashHintIndex = min(
                        viewModel.slashHints.count - 1,
                        selectedSlashHintIndex + 1
                    )
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    guard viewModel.isSlashHintMenuVisible else { return .ignored }
                    viewModel.draft = ""
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    guard viewModel.isSlashHintMenuVisible,
                          viewModel.slashHints.indices.contains(selectedSlashHintIndex)
                    else { return .ignored }
                    viewModel.acceptSlashHint(viewModel.slashHints[selectedSlashHintIndex])
                    return .handled
                }

                if let voiceLiveEntry {
                    VoiceLiveComposerButton(entry: voiceLiveEntry)
                }

                Button("Send") {
                    sendDraft()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSendComposer)
            }
            .padding(14)
        }
    }

    private var canSendComposer: Bool {
        guard viewModel.isStarted else { return false }
        let hasText = !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !attachmentSlots.attachments.isEmpty
    }

    private var agentAttachmentStrip: some View {
        HStack(spacing: 8) {
            if attachmentSlots.isEncoding {
                ProgressView()
                    .controlSize(.mini)
            }
            ForEach(attachmentSlots.attachments) { attachment in
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.caption)
                    Text(attachment.filename ?? "Image")
                        .font(.caption2)
                        .lineLimit(1)
                    Button {
                        attachmentSlots.remove(id: attachment.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.4), in: Capsule())
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            Text("\(attachmentSlots.attachments.count)/\(ComposerAttachmentSlots.defaultCapacity)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var backendDisplayName: String {
        switch project.preferredAgentID {
        case .claudeCode: return "Claude Code"
        case .hermes: return "Hermes"
        default: return project.preferredAgentID.rawValue
        }
    }

    private func startAndConsumeHandoff() async {
        var initialPrompt: String?
        if coordinator.pendingProjectChat == project.rootPath {
            initialPrompt = coordinator.pendingInitialPrompt
            coordinator.pendingProjectChat = nil
            coordinator.pendingInitialPrompt = nil
        }

        await viewModel.start()

        guard viewModel.isStarted,
              let initialPrompt,
              !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        try? await viewModel.send(initialPrompt)
    }

    private func submitComposer() {
        // Enter while the slash menu is open inserts the highlighted hint so
        // the user can add arguments. Explicit Send / ⌘↩ always transmits.
        if viewModel.isSlashHintMenuVisible,
           viewModel.slashHints.indices.contains(selectedSlashHintIndex)
        {
            viewModel.acceptSlashHint(viewModel.slashHints[selectedSlashHintIndex])
            return
        }
        sendDraft()
    }

    private func sendDraft() {
        guard viewModel.isStarted else { return }
        let images = attachmentSlots.drain()
        Task { try? await viewModel.sendDraft(images: images) }
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            attachmentError = "Couldn't open image"
            scheduleAttachmentErrorClear()
        case .success(let urls):
            let granted = attachmentSlots.reserve(upTo: urls.count)
            guard granted > 0 else {
                attachmentError = "Limit of \(ComposerAttachmentSlots.defaultCapacity) images reached"
                scheduleAttachmentErrorClear()
                return
            }
            for url in urls.prefix(granted) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    attachmentSlots.release()
                    continue
                }
                encodeAttachment(data: data, filename: url.lastPathComponent)
            }
        }
    }

    private func ingestImageProviders(_ providers: [NSItemProvider]) {
        let granted = attachmentSlots.reserve(upTo: providers.count)
        guard granted > 0 else {
            attachmentError = "Limit of \(ComposerAttachmentSlots.defaultCapacity) images reached"
            scheduleAttachmentErrorClear()
            return
        }
        for provider in providers.prefix(granted) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else {
                        Task { @MainActor in
                            attachmentSlots.release()
                            attachmentError = "Couldn't read dropped file"
                            scheduleAttachmentErrorClear()
                        }
                        return
                    }
                    Task { @MainActor in
                        encodeAttachment(data: data, filename: url.lastPathComponent)
                    }
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else {
                        Task { @MainActor in
                            attachmentSlots.release()
                        }
                        return
                    }
                    Task { @MainActor in
                        encodeAttachment(data: data, filename: nil)
                    }
                }
                continue
            }
            attachmentSlots.release()
        }
    }

    private func encodeAttachment(data: Data, filename: String?) {
        Task {
            do {
                let attachment = try await Task.detached {
                    try ImageEncoder().encode(rawBytes: data, sourceFilename: filename)
                }.value
                await MainActor.run {
                    attachmentSlots.commit(attachment)
                }
            } catch {
                await MainActor.run {
                    attachmentSlots.release()
                    attachmentError = "Couldn't encode image"
                    scheduleAttachmentErrorClear()
                }
            }
        }
    }

    private func scheduleAttachmentErrorClear() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { attachmentError = nil }
        }
    }
}

private struct AgentMessageRow: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if showsSpeakButton {
                    SpeakMessageButton(
                        messageId: message.id.speechPlaybackMessageId,
                        content: message.content
                    )
                }
                Spacer(minLength: 0)
            }
            Text(message.content)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Per-message TTS (parity with `RichMessageBubble`): settled assistant
    /// replies with non-empty content. Uses the shared `MessageSpeechService`
    /// path — system voice always; Hermes Voice when Settings + capabilities allow.
    private var showsSpeakButton: Bool {
        message.role == .assistant && !message.content.isEmpty
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }
}

/// Reasoning draft honoring Settings → Display → Chat density.
private struct AgentReasoningDraftView: View {
    let text: String
    let style: ReasoningStyle

    var body: some View {
        switch style {
        case .hidden:
            EmptyView()
        case .inline:
            Text(text)
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .disclosure:
            DisclosureGroup {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Expanded activity log: tools, commands (with expandable output), file
/// changes, usage. Honors `ToolCardStyle` compact vs full.
private struct AgentActivitySummary: View {
    let state: AgentConversationState
    var toolStyle: ToolCardStyle = .full

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(state.toolCalls) { call in
                toolRow(call)
            }

            ForEach(state.commands) { command in
                commandRow(command)
            }

            ForEach(Array(state.fileChanges.enumerated()), id: \.offset) { _, change in
                HStack(spacing: 6) {
                    Image(systemName: fileChangeIcon(change.kind))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(change.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(change.kind.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let usage = state.usage {
                Divider()
                Text(usageSummary(usage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func toolRow(_ call: AgentToolCall) -> some View {
        let result = state.toolResults[call.id]
        let detail = toolDetailText(call: call, result: result)
        if toolStyle == .compact || detail == nil {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: toolIcon(for: call.status))
                    .foregroundStyle(toolColor(for: call.status))
                    .font(.caption)
                Text("\(call.title) · \(call.kind)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        } else if let detail {
            DisclosureGroup {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolIcon(for: call.status))
                        .foregroundStyle(toolColor(for: call.status))
                        .font(.caption)
                    Text("\(call.title) · \(call.kind)")
                        .font(.caption.weight(.medium))
                }
            }
        }
    }

    @ViewBuilder
    private func commandRow(_ command: AgentCommand) -> some View {
        let output = commandOutputText(for: command.id)
        if let output, !output.isEmpty {
            DisclosureGroup {
                Text(output)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                commandLabel(command)
            }
        } else {
            commandLabel(command)
        }
    }

    private func commandLabel(_ command: AgentCommand) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(command.command)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(commandStatusLabel(command.status))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func toolDetailText(call: AgentToolCall, result: AgentToolResult?) -> String? {
        var parts: [String] = []
        if let input = call.input, !input.isEmpty { parts.append(input) }
        if let output = result?.output, !output.isEmpty { parts.append(output) }
        if let error = result?.errorMessage, !error.isEmpty { parts.append(error) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    private func commandOutputText(for commandID: String) -> String? {
        var parts: [String] = []
        if let streamed = state.commandOutput[commandID], !streamed.isEmpty {
            parts.append(streamed)
        }
        if let result = state.commandResults[commandID] {
            if let output = result.output, !output.isEmpty { parts.append(output) }
            if let err = result.errorOutput, !err.isEmpty { parts.append(err) }
            if let code = result.exitCode {
                parts.append("exit \(code)")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private func toolIcon(for status: AgentToolStatus) -> String {
        switch status {
        case .pending: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .cancelled: return "slash.circle"
        }
    }

    private func toolColor(for status: AgentToolStatus) -> Color {
        switch status {
        case .pending, .running: return .secondary
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private func commandStatusLabel(_ status: AgentCommandStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .running: return "running"
        case .completed: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private func fileChangeIcon(_ kind: AgentFileChangeKind) -> String {
        switch kind {
        case .created: return "plus.circle"
        case .modified: return "pencil.circle"
        case .deleted: return "minus.circle"
        case .renamed: return "arrow.right.circle"
        case .unknown: return "doc.circle"
        }
    }

    private func usageSummary(_ usage: AgentUsage) -> String {
        var parts = ["\(usage.inputTokens) in", "\(usage.outputTokens) out"]
        if usage.reasoningTokens > 0 {
            parts.append("\(usage.reasoningTokens) reasoning")
        }
        if usage.cachedReadTokens > 0 {
            parts.append("\(usage.cachedReadTokens) cached")
        }
        return parts.joined(separator: " · ")
    }
}

/// Informational (non-error) inline banner — missing credentials, idle
/// slash-command rewrite notices. Visually distinct from
/// ``AgentInlineError``'s warning tone.
private struct AgentInlineBanner: View {
    let icon: String
    let title: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.callout.weight(.semibold))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentInlineError: View {
    let title: String
    let message: String
    var retryTitle: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let retryTitle, let onRetry {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
