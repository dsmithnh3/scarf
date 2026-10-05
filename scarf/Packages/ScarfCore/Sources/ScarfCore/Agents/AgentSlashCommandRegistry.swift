import Foundation

/// Where a registered slash command may run.
public enum AgentSlashCommandExecution: String, Codable, Equatable, Hashable, Sendable {
    /// Intercepted and handled inside Scarf (composer / local expansion).
    case local
    /// Forwarded to the active backend as literal slash text or an equivalent
    /// backend-native invocation once that path is wired.
    case forwardToBackend
}

/// Which backends may surface a registered slash command.
public enum AgentSlashCommandBackendScope: Codable, Equatable, Hashable, Sendable {
    /// Scarf-owned command available regardless of active backend.
    case scarfLocal
    /// Only the listed backends may advertise this command.
    case backends(Set<AgentID>)

    public func includes(_ backendID: AgentID) -> Bool {
        switch self {
        case .scarfLocal:
            return true
        case .backends(let ids):
            return ids.contains(backendID)
        }
    }
}

/// Backend-neutral slash-command metadata for a Scarf-native registry.
///
/// This is intentionally separate from ``HermesSlashCommand`` (Hermes ACP /
/// project-scoped menu model) and from ``AgentCommand`` (shell/tool activity
/// inside a conversation transcript). No UI transplant from CLUI — composers
/// consume this model later through Scarf styling.
public struct AgentSlashCommandDescriptor: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }

    public var name: String
    public var description: String
    public var aliases: [String]
    public var backendScope: AgentSlashCommandBackendScope
    public var requiredCapabilities: AgentCapabilities
    public var argumentHint: String?
    public var execution: AgentSlashCommandExecution
    public var category: String?

    public init(
        name: String,
        description: String,
        aliases: [String] = [],
        backendScope: AgentSlashCommandBackendScope,
        requiredCapabilities: AgentCapabilities = [],
        argumentHint: String? = nil,
        execution: AgentSlashCommandExecution,
        category: String? = nil
    ) {
        self.name = name
        self.description = description
        self.aliases = aliases
        self.backendScope = backendScope
        self.requiredCapabilities = requiredCapabilities
        self.argumentHint = argumentHint
        self.execution = execution
        self.category = category
    }

    public func isAvailable(
        backendID: AgentID,
        capabilities: AgentCapabilities
    ) -> Bool {
        guard backendScope.includes(backendID) else { return false }
        return capabilities.contains(requiredCapabilities)
    }
}

/// Pure in-memory registry that merges Scarf-local and backend-scoped commands.
///
/// First registration wins on name collisions so Scarf-local entries can
/// shadow backend duplicates when both are registered in that order. Filtering
/// is capability- and backend-aware; there is no CLUI UI or composer wiring yet.
public struct AgentSlashCommandRegistry: Sendable, Equatable {
    public private(set) var commands: [AgentSlashCommandDescriptor]

    public init(commands: [AgentSlashCommandDescriptor] = []) {
        var seen: Set<String> = []
        var unique: [AgentSlashCommandDescriptor] = []
        for command in commands {
            let key = command.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(command)
        }
        self.commands = unique
    }

    public func availableCommands(
        backendID: AgentID,
        capabilities: AgentCapabilities
    ) -> [AgentSlashCommandDescriptor] {
        commands.filter { $0.isAvailable(backendID: backendID, capabilities: capabilities) }
    }

    public func matchingCommands(
        query: String,
        backendID: AgentID,
        capabilities: AgentCapabilities
    ) -> [AgentSlashCommandDescriptor] {
        let available = availableCommands(backendID: backendID, capabilities: capabilities)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return available }

        let needle = trimmed.lowercased()
        return available.filter { command in
            if command.name.lowercased().hasPrefix(needle) { return true }
            return command.aliases.contains { $0.lowercased().hasPrefix(needle) }
        }
    }
}
