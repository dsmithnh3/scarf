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
    public var source: AgentSlashCommandCatalogSource

    public init(
        name: String,
        description: String,
        aliases: [String] = [],
        backendScope: AgentSlashCommandBackendScope,
        requiredCapabilities: AgentCapabilities = [],
        argumentHint: String? = nil,
        execution: AgentSlashCommandExecution,
        category: String? = nil,
        source: AgentSlashCommandCatalogSource = .scarfLocal
    ) {
        self.name = name
        self.description = description
        self.aliases = aliases
        self.backendScope = backendScope
        self.requiredCapabilities = requiredCapabilities
        self.argumentHint = argumentHint
        self.execution = execution
        self.category = category
        self.source = source
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

    /// Backend-aware hint rows for a Scarf-native slash menu (no UI yet).
    public func hints(
        matching query: String = "",
        backendID: AgentID,
        capabilities: AgentCapabilities
    ) -> [AgentSlashCommandHint] {
        matchingCommands(
            query: query,
            backendID: backendID,
            capabilities: capabilities
        ).map { command in
            AgentSlashCommandHint(
                name: command.name,
                description: command.description,
                argumentHint: command.argumentHint,
                source: command.source,
                execution: command.execution
            )
        }
    }

    /// Merge live Hermes ACP advertisements into this registry.
    ///
    /// Precedence mirrors Hermes chat: live ACP names supersede the static
    /// Hermes fallback roster, while Scarf-local commands stay first-wins.
    /// Static Hermes entries whose names are absent from `live` remain so
    /// resumed sessions without a re-emitted `available_commands_update` keep
    /// discoverable affordances (same reason as
    /// `RichChatViewModel.alwaysAvailableCommands`).
    public func mergingLiveHermesACPCommands(
        _ live: [AgentSlashCommandDescriptor]
    ) -> AgentSlashCommandRegistry {
        let scarfLocal = commands.filter { $0.source == .scarfLocal }
        let staticHermes = commands.filter { $0.source == .hermes }
        let other = commands.filter { $0.source != .scarfLocal && $0.source != .hermes }

        let liveNames = Set(live.map { $0.name.lowercased() })
        let remainingStatic = staticHermes.filter {
            !liveNames.contains($0.name.lowercased())
        }

        // Normalize live rows to Hermes scope even if a caller forgot.
        let normalizedLive = live.map { command in
            AgentSlashCommandDescriptor(
                name: command.name,
                description: command.description,
                aliases: command.aliases,
                backendScope: .backends([.hermes]),
                requiredCapabilities: command.requiredCapabilities,
                argumentHint: command.argumentHint,
                execution: command.execution,
                category: command.category,
                source: .hermes
            )
        }

        return AgentSlashCommandRegistry(
            commands: scarfLocal + normalizedLive + remainingStatic + other
        )
    }
}
