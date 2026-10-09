import Foundation

/// Routes Hermes project chats through `AgentChat` instead of legacy `ChatView`.
///
/// Default is **on** after the production-B soak. Users can turn the flag off
/// in Settings → Agent Backends to keep the ChatView escape hatch. When the
/// key is absent, Scarf treats AgentChat as the Hermes path (not `bool`'s
/// false-for-missing semantics).
enum HermesAgentChatOptIn {
    static let userDefaultsKey = "scarf.experimental.hermesAgentChat"

    /// Reads the live UserDefaults value. Missing key → enabled (default on).
    static var isEnabled: Bool {
        isEnabled(in: .standard)
    }

    /// Testable read against an arbitrary defaults suite.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: userDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: userDefaultsKey)
    }
}
