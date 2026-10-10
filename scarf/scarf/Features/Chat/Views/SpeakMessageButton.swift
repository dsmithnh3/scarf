import SwiftUI
import ScarfCore
import ScarfDesign

/// Stand-alone speaker button so `MessageSpeechService` observation doesn't
/// get short-circuited by parent `Equatable` views. Only the button re-renders
/// when playback flips.
///
/// The message's server comes from the environment the bubble renders in —
/// the window's profile-scoped `\.serverContext` — and travels with every
/// toggle so Hermes Voice synthesizes on the server the message came from.
struct SpeakMessageButton: View {
    let messageId: Int
    let content: String

    @State private var speech = MessageSpeechService.shared
    @State private var liveVoice = VoiceLiveSessionRegistry.shared
    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    var body: some View {
        let id = MessageSpeechService.PlaybackID(server: serverContext, messageId: messageId)
        let state = SpeakMessageButtonState(
            isPlaying: speech.isPlaying(id),
            isLoading: speech.loading == id,
            liveVoiceActive: liveVoice.isAnySessionActive,
            fallbackReason: speech.fallbackNotice?.id == id ? speech.fallbackNotice?.reason : nil
        )
        HStack(spacing: 2) {
            Button {
                speech.toggle(id, content: content, capabilities: capabilitiesStore?.capabilities ?? .empty)
            } label: {
                Group {
                    if state.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: state.isPlaying ? "stop.circle.fill" : "speaker.wave.2")
                            .font(.system(size: 11))
                            .foregroundStyle(state.isPlaying ? ScarfColor.accent : ScarfColor.foregroundFaint)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(!state.isEnabled)
            .help(state.help)
            .accessibilityLabel(state.accessibilityLabel)
            .accessibilityValue(state.accessibilityValue)
            if state.fallbackReason != nil, state.isPlaying {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(ScarfColor.warning)
                    .help(state.help)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension UUID {
    /// Stable Int key for ``MessageSpeechService/PlaybackID`` when the
    /// message identity is a UUID (AgentChat) rather than a Hermes `state.db`
    /// row id. Collisions across messages in one window are astronomically
    /// unlikely; cross-window isolation still comes from `ServerContext`.
    var speechPlaybackMessageId: Int {
        withUnsafeBytes(of: uuid) { raw in
            raw.load(as: Int.self)
        }
    }
}
