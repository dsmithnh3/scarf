import SwiftUI
import ScarfCore
import ScarfDesign

/// Read-only multi-agent runtime status shown above Hermes' existing Agent
/// settings. This is intentionally observational: it does not select a backend,
/// alter project preferences, or route existing Hermes chat through AgentRuntime.
struct AgentBackendsSettingsView: View {
    let viewModel: SettingsViewModel
    @State private var statusModel: AgentBackendsStatusViewModel

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
                    .lineLimit(2)
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
        switch snapshot.status {
        case .available(let version):
            if let version, !version.isEmpty { return version }
            return snapshot.id == .hermes ? "Hermes runtime detected" : "Runtime detected"
        case .notInstalled:
            return snapshot.id == .claudeCode
                ? "Claude Code executable was not found"
                : "Runtime executable was not found"
        case .unavailable(let reason):
            return reason
        }
    }
}
