import Foundation

/// Distinct extension systems Scarf may catalog.
///
/// These are intentionally separate cases — a unified catalog must not pretend
/// Hermes plugins, Hermes skills, Claude skills, MCP servers, and Scarf-local
/// extensions are the same kind of thing.
public enum AgentExtensionKind: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case hermesPlugin
    case hermesSkill
    case claudeCodeSkill
    case mcpServer
    case scarfLocal
}

/// Origin catalog for an extension entry.
public enum AgentExtensionCatalogSource: String, Codable, Equatable, Hashable, Sendable {
    case hermes
    case claudeCode
    case scarfLocal
}

/// Which backends may surface a catalogued extension.
public enum AgentExtensionBackendScope: Codable, Equatable, Hashable, Sendable {
    /// Scarf-owned extension available regardless of active backend.
    case scarfLocal
    /// Only the listed backends may advertise this extension.
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

/// Enablement / discovery state for one catalog entry.
///
/// Mirrors Hermes plugin activation (`enabled` / `disabled` / `not enabled`)
/// plus a truthful unknown for unverified discovery stubs. Does not invent
/// Claude skill availability.
public enum AgentExtensionAvailability: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// Loaded / enabled for use.
    case available
    /// Explicitly disabled by the user or config.
    case disabled
    /// Installed but absent from enable lists (Hermes plugin `not enabled`).
    case notEnabled
    /// Discovery path not verified; do not claim the extension exists.
    case unknown
}

/// Backend-neutral extension metadata for a Scarf-native catalog.
///
/// Separate from Hermes feature VMs (`PluginsViewModel`, `SkillsViewModel`,
/// `MCPServersViewModel`) and from CLUI overlays — UI consumes this model
/// later through Scarf styling.
public struct AgentExtensionDescriptor: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Composite id so the same display name under different kinds stays distinct.
    public var id: String { "\(kind.rawValue):\(name)" }

    public var name: String
    public var description: String
    public var kind: AgentExtensionKind
    public var source: AgentExtensionCatalogSource
    public var backendScope: AgentExtensionBackendScope
    public var availability: AgentExtensionAvailability
    public var requiredCapabilities: AgentCapabilities
    public var version: String?
    public var category: String?
    public var path: String?

    public init(
        name: String,
        description: String,
        kind: AgentExtensionKind,
        source: AgentExtensionCatalogSource,
        backendScope: AgentExtensionBackendScope,
        availability: AgentExtensionAvailability,
        requiredCapabilities: AgentCapabilities = [],
        version: String? = nil,
        category: String? = nil,
        path: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.source = source
        self.backendScope = backendScope
        self.availability = availability
        self.requiredCapabilities = requiredCapabilities
        self.version = version
        self.category = category
        self.path = path
    }

    /// Backend + capability gate (enablement is filtered separately via
    /// ``availability``).
    public func isInScope(
        backendID: AgentID,
        capabilities: AgentCapabilities
    ) -> Bool {
        guard backendScope.includes(backendID) else { return false }
        return capabilities.contains(requiredCapabilities)
    }
}

/// Pure in-memory catalog that merges distinct extension sources.
///
/// First registration wins on composite-id collisions. Filtering is
/// backend-, capability-, kind-, and availability-aware. No CLUI UI.
public struct AgentExtensionCatalog: Sendable, Equatable {
    public private(set) var entries: [AgentExtensionDescriptor]

    public init(entries: [AgentExtensionDescriptor] = []) {
        var seen: Set<String> = []
        var unique: [AgentExtensionDescriptor] = []
        for entry in entries {
            let key = entry.id.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(entry)
        }
        self.entries = unique
    }

    public func matching(
        backendID: AgentID,
        capabilities: AgentCapabilities,
        kinds: Set<AgentExtensionKind>? = nil,
        availability: Set<AgentExtensionAvailability>? = nil
    ) -> [AgentExtensionDescriptor] {
        entries.filter { entry in
            guard entry.isInScope(backendID: backendID, capabilities: capabilities) else {
                return false
            }
            if let kinds, !kinds.contains(entry.kind) {
                return false
            }
            if let availability, !availability.contains(entry.availability) {
                return false
            }
            return true
        }
    }
}
