import SwiftUI
import ScarfCore
import ScarfDesign

/// Strangler router for Chat.
///
/// Plain Chat and Hermes projects (flag off) still render the original
/// `ChatView`. Hermes projects with `scarf.experimental.hermesAgentChat` on,
/// and projects that prefer a non-Hermes backend, reach the generic surface.
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
    @State private var selectedSlashHintIndex = 0
    @State private var isExtensionsSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .task(id: project.rootPath) {
            await startAndConsumeHandoff()
        }
        .onDisappear {
            Task { await viewModel.close() }
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
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

            if viewModel.supportsModelPicker, !viewModel.availableModels.isEmpty {
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
            } else if let modelLabel = viewModel.modelBadgeLabel {
                Text(modelLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .padding(.horizontal, ScarfSpace.s2)
                    .padding(.vertical, ScarfSpace.s1)
                    .background(ScarfColor.backgroundSecondary, in: Capsule())
                    .help("Models advertised by this backend (read-only)")
                    .accessibilityLabel("Models: \(modelLabel)")
            } else if viewModel.isLoadingModels {
                ProgressView()
                    .controlSize(.mini)
            }

            // Hermes-only: Claude Code has no `session/set_mode` RPC, so the
            // picker never renders there. Shown unconditionally for Hermes
            // (rather than gated behind a live capability check) so the user
            // always has an explanation — `selectApprovalMode` itself is a
            // safe no-op on a host that can't honor it.
            if project.preferredAgentID == .hermes, viewModel.isStarted {
                ChatApprovalModeBadge(mode: viewModel.activeApprovalMode) { mode in
                    Task { await viewModel.selectApprovalMode(mode) }
                }
            }

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

                if let startupError = viewModel.startupError {
                    AgentInlineError(
                        title: "Could not start \(backendDisplayName)",
                        message: startupError
                    )
                }

                if let error = viewModel.state.error {
                    AgentInlineError(title: "Agent error", message: error.message)
                }

                if let lastActionError = viewModel.lastActionError {
                    AgentInlineError(title: "Action failed", message: lastActionError)
                }

                if let idleSlashNotice = viewModel.idleSlashNotice {
                    AgentInlineBanner(icon: "info.circle", title: nil, message: idleSlashNotice)
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

                if !viewModel.state.reasoningDraft.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.state.reasoningDraft)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !viewModel.state.assistantDraft.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assistant")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.state.assistantDraft)
                            .textSelection(.enabled)
                    }
                }

                if !viewModel.state.toolCalls.isEmpty
                    || !viewModel.state.commands.isEmpty
                    || !viewModel.state.fileChanges.isEmpty
                    || viewModel.state.usage != nil {
                    AgentActivitySummary(state: viewModel.state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Message \(backendDisplayName)…",
                    text: $viewModel.draft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit { submitComposer() }
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

                Button("Send") {
                    sendDraft()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    !viewModel.isStarted
                        || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(14)
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
        Task { try? await viewModel.sendDraft() }
    }
}

private struct AgentMessageRow: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(roleLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.content)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Expanded activity log: every tool call's title + input, every command
/// line, every file-change path, and the running token usage when the
/// backend reports it. Replaces the earlier count-only summary so a user
/// can see WHAT ran, not just how many things did.
private struct AgentActivitySummary: View {
    let state: AgentConversationState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(state.toolCalls) { call in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: toolIcon(for: call.status))
                        .foregroundStyle(toolColor(for: call.status))
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(call.title) · \(call.kind)")
                            .font(.caption.weight(.medium))
                        if let input = call.input, !input.isEmpty {
                            Text(input)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            ForEach(state.commands) { command in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
