import Foundation

/// Parses Hermes ACP `available_commands_update` payloads into Scarf-native
/// slash descriptors.
///
/// Shape matches `RichChatViewModel.parseACPCommands` / ACP
/// `availableCommands` entries: `name` (optional leading `/`), `description`,
/// optional `input.hint`. No Claude invention — Claude discovery stays empty
/// until a verified source exists.
public enum AgentSlashCommandACPDiscovery: Sendable {
    /// Convert verified ACP command dictionaries into Hermes-scoped registry
    /// descriptors. Invalid / blank names are skipped.
    public static func descriptors(
        fromACPCommands commands: [[String: Any]]
    ) -> [AgentSlashCommandDescriptor] {
        var result: [AgentSlashCommandDescriptor] = []
        var seen: Set<String> = []
        for entry in commands {
            guard let rawName = entry["name"] as? String else { continue }
            let name = rawName
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let description = (entry["description"] as? String) ?? ""
            var hint: String?
            if let input = entry["input"] as? [String: Any],
               let h = input["hint"] as? String,
               !h.isEmpty {
                hint = h
            }

            result.append(
                AgentSlashCommandDescriptor(
                    name: name,
                    description: description,
                    backendScope: .backends([.hermes]),
                    argumentHint: hint,
                    execution: .forwardToBackend,
                    category: "session",
                    source: .hermes
                )
            )
        }
        return result
    }
}
