import Foundation

/// Experimental opt-in for routing Hermes project chats through `AgentChat`
/// instead of legacy `ChatView`.
///
/// Default is **off** — ChatView remains the production Hermes path until a
/// separate default-flip task after soak. When on, Hermes projects use the same
/// `AgentRuntime` / `HermesBackend` wiring as Claude-preferred projects.
enum HermesAgentChatOptIn {
    static let userDefaultsKey = "scarf.experimental.hermesAgentChat"

    /// Reads the live UserDefaults value. Default (missing key) is `false`.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
}
