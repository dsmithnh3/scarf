import SwiftUI
import ScarfCore
import ScarfDesign

/// Scarf-native pending-permission card for multi-agent project chat.
///
/// Renders the coordinator FIFO head from ``AgentPermissionPresentation``.
/// Option buttons call respond; Cancel calls cancelPermission. Uses ScarfDesign
/// tokens only — not a CLUI / Rich Chat `PermissionApprovalView` transplant.
struct AgentPermissionCard: View {
    let presentation: AgentPermissionPresentation
    var onRespond: (AgentPermissionRequest, String) -> Void
    var onCancel: (AgentPermissionRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                Image(systemName: kindIcon)
                    .foregroundStyle(kindColor)
                Text("Permission required")
                    .scarfStyle(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer(minLength: 0)
                if presentation.pendingCount > 1 {
                    Text("\(presentation.pendingCount) waiting")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }

            ScrollView {
                Text(presentation.title)
                    .font(ScarfFont.mono)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            if let detail = presentation.detail, !detail.isEmpty {
                Text(detail)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }

            HStack(spacing: ScarfSpace.s2) {
                ForEach(presentation.options) { option in
                    if optionLooksLikeDeny(option) {
                        Button(option.title) {
                            onRespond(presentation.request, option.id)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(option.title) {
                            onRespond(presentation.request, option.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ScarfColor.accent)
                    }
                }

                Spacer(minLength: 0)

                Button("Cancel") {
                    onCancel(presentation.request)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(ScarfSpace.s3)
        .scarfChromeGlass()
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .strokeBorder(ScarfColor.borderStrong, lineWidth: 0.5)
        )
        .scarfShadow(ScarfShadow.md)
    }

    private var kindIcon: String {
        switch (presentation.detail ?? "").lowercased() {
        case "edit", "write": return "pencil"
        case "execute", "bash", "shell": return "terminal"
        case "read": return "doc.text"
        case "fetch", "web": return "globe"
        default: return "hand.raised"
        }
    }

    private var kindColor: Color {
        switch (presentation.detail ?? "").lowercased() {
        case "edit", "write": return ScarfColor.info
        case "execute", "bash", "shell": return ScarfColor.warning
        case "read": return ScarfColor.success
        default: return ScarfColor.accent
        }
    }

    private func optionLooksLikeDeny(_ option: AgentPermissionOption) -> Bool {
        let id = option.id.lowercased()
        let title = option.title.lowercased()
        return id.contains("deny") || id.contains("reject") || title.contains("deny")
    }
}
