import Foundation

public extension ScarfProject {
    /// Backend selected for new agent sessions in this project.
    ///
    /// Stored in `extra` so the existing lenient/unknown-key-preserving
    /// `ScarfProject` Codable implementation carries the preference without a
    /// schema bump. Projects created before multi-agent support have no key and
    /// therefore continue to use Hermes exactly as before.
    var preferredAgentID: AgentID {
        get {
            guard case .string(let raw)? = extra["preferredAgentId"], !raw.isEmpty else {
                return .hermes
            }
            return AgentID(raw)
        }
        set {
            if newValue == .hermes {
                // Hermes is the compatibility default. Omitting the key keeps
                // legacy project.json records minimal and semantically
                // identical to pre-multi-agent files.
                extra.removeValue(forKey: "preferredAgentId")
            } else {
                extra["preferredAgentId"] = .string(newValue.rawValue)
            }
        }
    }
}
