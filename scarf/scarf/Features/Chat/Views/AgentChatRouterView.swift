import SwiftUI
import ScarfCore

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
    let viewModel: AgentChatViewModel

    @Environment(AppCoordinator.self) private var coordinator
    @State private var draft = ""

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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message \(backendDisplayName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit { sendDraft() }

            Button("Send") {
                sendDraft()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.isStarted || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
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

    private func sendDraft() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, viewModel.isStarted else { return }
        draft = ""
        Task { try? await viewModel.send(message) }
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
