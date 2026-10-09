import SwiftUI
import ScarfCore
import ScarfDesign

/// Scarf-native slash hint list for the multi-agent composer.
///
/// Reuses ScarfDesign tokens from the Hermes `SlashCommandMenu` (mono name,
/// caption description, accent selection tint) without importing CLUI/Opal
/// pill chrome. Rows bind to ``AgentSlashCommandHint`` from ScarfCore.
struct AgentSlashHintMenu: View {
    let presentation: AgentSlashHintPresentation
    @Binding var selectedIndex: Int
    var onSelect: (AgentSlashCommandHint) -> Void

    var body: some View {
        Group {
            if presentation.catalogIsEmpty {
                emptyState(
                    title: "No commands available",
                    detail: "This backend has no Scarf slash commands yet. Keep typing to send as a message, or press Esc."
                )
            } else if presentation.hints.isEmpty {
                emptyState(
                    title: "No matching commands",
                    detail: "Keep typing to send as a message, or press Esc."
                )
            } else {
                hintList
            }
        }
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.xl)
                .strokeBorder(ScarfColor.borderStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.xl))
        .scarfShadow(ScarfShadow.md)
    }

    private var hintList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(presentation.hints.enumerated()), id: \.element.id) { index, hint in
                        AgentSlashHintRow(
                            hint: hint,
                            isSelected: index == selectedIndex
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            onSelect(hint)
                        }
                    }
                }
            }
            .frame(minWidth: 360, maxHeight: 260)
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scarfStyle(.callout)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(detail)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
        .padding(ScarfSpace.s3)
        .frame(minWidth: 360, alignment: .leading)
    }
}

private struct AgentSlashHintRow: View {
    let hint: AgentSlashCommandHint
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hint.slashName)
                        .font(ScarfFont.mono)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                    if let argumentHint = hint.argumentHint {
                        let display = argumentHint.hasPrefix("<") || argumentHint.hasPrefix("[")
                            ? argumentHint
                            : "<\(argumentHint)>"
                        Text(display)
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
                    sourceBadge
                }
                if !hint.description.isEmpty {
                    Text(hint.description)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .background(isSelected ? ScarfColor.accentTint : Color.clear)
    }

    @ViewBuilder
    private var sourceBadge: some View {
        let label: String? = {
            switch hint.source {
            case .scarfLocal: return "Scarf"
            case .hermes: return "Hermes"
            case .claudeCode: return "Claude"
            }
        }()
        if let label {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
    }
}
