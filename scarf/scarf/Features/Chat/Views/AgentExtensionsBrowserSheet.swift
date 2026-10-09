import SwiftUI
import ScarfCore
import ScarfDesign

/// Read-only extensions browser for multi-agent project chat.
///
/// Renders ``AgentExtensionBrowserPresentation`` only — no install, toggle,
/// reload, or path editor. Hermes management stays on the Plugins / Skills /
/// MCP Servers sidebar screens.
struct AgentExtensionsBrowserSheet: View {
    let presentation: AgentExtensionBrowserPresentation
    let isLoading: Bool
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(ScarfColor.backgroundPrimary)
    }

    private var header: some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(ScarfColor.accent)
            Text("Extensions")
                .scarfStyle(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
            Button("Done") { onDismiss() }
                .buttonStyle(.bordered)
                .disabled(isLoading)
        }
        .padding(ScarfSpace.s3)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: ScarfSpace.s3) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading catalog…")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(ScarfSpace.s4)
        } else if presentation.isEmpty {
            ContentUnavailableView {
                Label("No extensions", systemImage: "puzzlepiece.extension")
            } description: {
                Text(presentation.emptyMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(presentation.sections) { section in
                    Section(section.title) {
                        if section.rows.isEmpty, section.isExplicitlyEmpty {
                            Text("No verified entries yet.")
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                        } else {
                            ForEach(section.rows) { row in
                                extensionRow(row)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func extensionRow(_ row: AgentExtensionBrowserRow) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                Text(row.name)
                    .scarfStyle(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer(minLength: 0)
                Text(row.availabilityLabel)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            if !row.description.isEmpty {
                Text(row.description)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, ScarfSpace.s1)
    }
}
