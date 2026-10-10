import SwiftUI
import AppKit
import ScarfDesign

struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied = false

    /// Chat font scale plumbed from `RichChatView` (issue #68). Defaults
    /// to 1.0 outside the chat surface.
    @Environment(\.chatFontScale) private var chatFontScale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language)
                        .font(ChatFontScale.caption2(chatFontScale).bold())
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Spacer()
                    copyButton
                }
                .padding(.horizontal, ScarfSpace.s3 - 2)
                .padding(.top, ScarfSpace.s2 - 2)
                .padding(.bottom, 2)
            } else {
                HStack {
                    Spacer()
                    copyButton
                }
                .padding(.horizontal, ScarfSpace.s3 - 2)
                .padding(.top, ScarfSpace.s2 - 2)
            }

            ScrollView(.horizontal) {
                Text(code)
                    .font(ChatFontScale.codeBlock(chatFontScale))
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, ScarfSpace.s3 - 2)
                    .padding(.bottom, ScarfSpace.s2)
                    .padding(.top, ScarfSpace.s1)
            }
            .scrollIndicators(.hidden)
        }
        .background(ScarfColor.backgroundTertiary)
        .clipShape(.rect(cornerRadius: ScarfRadius.lg))
    }

    private var copyButton: some View {
        Button("Copy code", systemImage: copied ? "checkmark" : "doc.on.doc", action: copyCode)
            .labelStyle(.iconOnly)
            .font(.caption)
            .foregroundStyle(copied ? ScarfColor.success : ScarfColor.foregroundMuted)
            .buttonStyle(.plain)
            .help("Copy code")
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
