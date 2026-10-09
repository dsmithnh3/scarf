import SwiftUI
import ScarfCore
import ScarfDesign

/// Strangler router for Chat.
///
/// Plain Chat, session resumes, and Hermes projects still render the original
/// `ChatView`. Only a project handoff whose canonical record explicitly selects
/// a non-Hermes backend reaches the generic surface.
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
            VStack(spacing: 8) {
                if let backendID {
                    Text("This project is configured for \(backendID.rawValue).")
                }
                Text(message)
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
                if let startupError = viewModel.startupError {
                    AgentInlineError(
                        title: "Could not start \(backendDisplayName)",
                        message: startupError
                    )
                }

                if let error = viewModel.state.error {
                    AgentInlineError(title: "Agent error", message: error.message)
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

                if !viewModel.state.toolCalls.isEmpty || !viewModel.state.commands.isEmpty {
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

private struct AgentActivitySummary: View {
    let state: AgentConversationState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !state.toolCalls.isEmpty {
                Text("\(state.toolCalls.count) tool call\(state.toolCalls.count == 1 ? "" : "s")")
                    .font(.caption)
            }
            if !state.commands.isEmpty {
                Text("\(state.commands.count) command\(state.commands.count == 1 ? "" : "s")")
                    .font(.caption)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
