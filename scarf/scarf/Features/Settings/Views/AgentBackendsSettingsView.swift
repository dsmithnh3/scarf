import SwiftUI
import ScarfCore
import ScarfDesign

/// Read-only multi-agent runtime status shown above Hermes' existing Agent
/// settings. This is intentionally observational: it does not select a backend,
/// alter project preferences, or route existing Hermes chat through AgentRuntime.
struct AgentBackendsSettingsView: View {
    let viewModel: SettingsViewModel
    @State private var statusModel: AgentBackendsStatusViewModel
    @AppStorage(HermesAgentChatOptIn.userDefaultsKey) private var hermesAgentChatEnabled = false

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        _statusModel = State(initialValue: AgentBackendsStatusViewModel(context: viewModel.context))
    }

    var body: some View {
        SettingsSection(title: "Agent Backends", icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                Text("Scarf can host multiple agent runtimes. Hermes remains the active production backend while Claude Code integration is introduced in isolated stages.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $hermesAgentChatEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use AgentChat for Hermes projects")
                            .scarfStyle(.body)
                        Text("Experimental. Routes Hermes project chats through the multi-agent AgentChat surface. ChatView remains the default when off and stays supported — turn this off anytime.")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Use AgentChat for Hermes projects")
                .accessibilityHint("Experimental. When on, Hermes project chats use AgentChat instead of ChatView. Off by default.")
                .help("Experimental opt-in. Hermes projects use AgentChat when enabled; ChatView remains the default escape hatch.")

                if statusModel.isLoading && statusModel.snapshots.isEmpty {
                    HStack(spacing: ScarfSpace.s2) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking agent backends…")
                            .scarfStyle(.footnote)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                } else {
                    ForEach(statusModel.snapshots) { snapshot in
                        AgentBackendStatusRow(snapshot: snapshot)
                    }
                }

                if viewModel.context.isRemote {
                    Text("Claude Code is local-only in this phase. Remote windows continue to use Hermes until remote Claude execution is implemented and verified.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorMessage = statusModel.errorMessage {
                    Text(errorMessage)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Refresh Status") {
                        Task { await statusModel.refresh() }
                    }
                    .buttonStyle(ScarfSecondaryButton())
                    .disabled(statusModel.isLoading)
                }
            }
        }
        .task {
            await statusModel.refresh()
        }

        // Preserve the complete existing Hermes settings surface unchanged.
        AgentTab(viewModel: viewModel)
    }
}

@MainActor
@Observable
final class AgentBackendsStatusViewModel {
    private let runtime: AgentRuntime

    private(set) var snapshots: [AgentBackendStatusSnapshot] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(context: ServerContext) {
        runtime = AgentRuntime(context: context)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        snapshots = await runtime.statusSnapshots()
    }
}

private struct AgentBackendStatusRow: View {
    let snapshot: AgentBackendStatusSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: ScarfSpace.s3) {
            Image(systemName: iconName)
                .frame(width: 18)
                .foregroundStyle(ScarfColor.foregroundMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayName)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(detailText)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(3)
            }

            Spacer(minLength: ScarfSpace.s3)

            Text(statusLabel)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .padding(.vertical, ScarfSpace.s1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.displayName), \(statusLabel), \(detailText)")
    }

    private var iconName: String {
        switch snapshot.status {
        case .available: return "checkmark.circle.fill"
        case .notInstalled: return "minus.circle"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var statusLabel: String {
        switch snapshot.status {
        case .available: return "Available"
        case .notInstalled: return "Not Installed"
        case .unavailable: return "Unavailable"
        }
    }

    private var detailText: String {
        AgentBackendStatusFormatting.detailText(for: snapshot)
    }
}
