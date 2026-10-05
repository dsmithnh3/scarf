import Foundation

/// Static/fixture adapters for Scarf-native extension catalog sources.
///
/// Hermes adapters map existing Scarf types when callers supply fixtures —
/// they do not walk the filesystem or invent discovery. Claude Code skills
/// stay an empty stub until Scarf verifies a real discovery source. Scarf-local
/// extensions are empty until one exists. Codex is deferred.
public enum AgentExtensionCatalogs: Sendable {

    /// Claude Code skill stub.
    ///
    /// Empty until Scarf verifies structured skill discovery for
    /// `ClaudeCodeBackend`. Do not invent a skills list here.
    public static let claudeCodeSkills: [AgentExtensionDescriptor] = []

    /// Scarf-owned extensions that are not Hermes/Claude/MCP-backed.
    ///
    /// Empty until a Scarf-local extension exists; the bundled projects MCP
    /// server is registered through Hermes MCP config, not this bucket.
    public static let scarfLocal: [AgentExtensionDescriptor] = []

    /// Map `hermes plugins list --json` rows (or equivalent fixtures).
    public static func hermesPlugins(
        from entries: [HermesPluginListEntry]
    ) -> [AgentExtensionDescriptor] {
        entries.map { entry in
            AgentExtensionDescriptor(
                name: entry.name,
                description: entry.description,
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: availability(from: entry.status),
                version: entry.version.isEmpty ? nil : entry.version
            )
        }
    }

    /// Map Hermes skill directory fixtures (`HermesSkill`).
    public static func hermesSkills(
        from skills: [HermesSkill]
    ) -> [AgentExtensionDescriptor] {
        skills.map { skill in
            AgentExtensionDescriptor(
                name: skill.name,
                description: skill.category.isEmpty
                    ? skill.name
                    : "\(skill.category)/\(skill.name)",
                kind: .hermesSkill,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: skill.enabled ? .available : .disabled,
                requiredCapabilities: [.skills],
                category: skill.category.isEmpty ? nil : skill.category,
                path: skill.path.isEmpty ? nil : skill.path
            )
        }
    }

    /// Map Hermes MCP server fixtures (`HermesMCPServer`).
    ///
    /// Read-only mapping only — callers that have no MCP config pass `[]`
    /// rather than inventing servers.
    public static func hermesMCPServers(
        from servers: [HermesMCPServer]
    ) -> [AgentExtensionDescriptor] {
        servers.map { server in
            AgentExtensionDescriptor(
                name: server.name,
                description: mcpDescription(for: server),
                kind: .mcpServer,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: server.enabled ? .available : .disabled,
                requiredCapabilities: [.mcp]
            )
        }
    }

    /// Production merge: Scarf-local first, then Hermes plugins / skills /
    /// MCP fixtures, then the empty Claude stub. Defaults stay empty so the
    /// catalog never invents extensions without a source.
    public static func makeCatalog(
        hermesPlugins: [HermesPluginListEntry] = [],
        hermesSkills: [HermesSkill] = [],
        hermesMCPServers: [HermesMCPServer] = []
    ) -> AgentExtensionCatalog {
        AgentExtensionCatalog(
            entries: scarfLocal
                + self.hermesPlugins(from: hermesPlugins)
                + self.hermesSkills(from: hermesSkills)
                + self.hermesMCPServers(from: hermesMCPServers)
                + claudeCodeSkills
        )
    }

    private static func availability(
        from status: HermesPluginActivation
    ) -> AgentExtensionAvailability {
        switch status {
        case .enabled:
            return .available
        case .disabled:
            return .disabled
        case .notEnabled:
            return .notEnabled
        }
    }

    private static func mcpDescription(for server: HermesMCPServer) -> String {
        switch server.transport {
        case .stdio:
            let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if command.isEmpty {
                return "MCP server (stdio)"
            }
            return "MCP server (stdio: \(command))"
        case .http:
            return "MCP server (http)"
        case .sse:
            return "MCP server (sse)"
        }
    }
}
