import Foundation

/// Injectable read-only Hermes loaders for the production extension catalog.
///
/// Call sites supply closures (tests) or use ``installed(context:transport:)``
/// which walks the real plugin/skill directories and reads MCP from config.yaml.
/// Claude discovery is never invented here — the empty stub stays in
/// ``AgentExtensionCatalogs/claudeCodeSkills``.
public struct AgentExtensionHermesLoaders: Sendable {
    public var loadPlugins: @Sendable () -> [HermesPluginListEntry]
    public var loadSkills: @Sendable () -> [HermesSkill]
    public var loadMCPServers: @Sendable () -> [HermesMCPServer]

    public init(
        loadPlugins: @escaping @Sendable () -> [HermesPluginListEntry] = { [] },
        loadSkills: @escaping @Sendable () -> [HermesSkill] = { [] },
        loadMCPServers: @escaping @Sendable () -> [HermesMCPServer] = { [] }
    ) {
        self.loadPlugins = loadPlugins
        self.loadSkills = loadSkills
        self.loadMCPServers = loadMCPServers
    }

    /// Production loaders against an installed Hermes home.
    ///
    /// - Plugins: ``HermesPluginDirectoryScanner`` (config activation lists)
    /// - Skills: ``SkillsScanner`` + `skills.disabled` from config.yaml
    /// - MCP: lightweight config.yaml roster (name / transport / enablement);
    ///   does not invent servers when the block is absent
    public static func installed(
        context: ServerContext,
        transport: any ServerTransport
    ) -> AgentExtensionHermesLoaders {
        AgentExtensionHermesLoaders(
            loadPlugins: {
                HermesPluginDirectoryScanner
                    .walk(dir: context.paths.pluginsDir, context: context)
                    .map { row in
                        HermesPluginListEntry(
                            name: row.name,
                            status: row.activation,
                            version: row.version,
                            description: row.source.isEmpty ? row.name : row.source,
                            source: row.source
                        )
                    }
            },
            loadSkills: {
                let disabled = AgentExtensionCatalogs.disabledSkillNames(
                    fromConfigYAML: context.readText(context.paths.configYAML) ?? ""
                )
                return SkillsScanner.scan(
                    context: context,
                    transport: transport,
                    disabledNames: disabled
                ).flatMap(\.skills)
            },
            loadMCPServers: {
                AgentExtensionCatalogs.hermesMCPServers(
                    fromConfigYAML: context.readText(context.paths.configYAML) ?? ""
                )
            }
        )
    }
}

extension AgentExtensionCatalogs {
    /// Merge results from injectable / production Hermes loaders.
    ///
    /// Claude and Scarf-local stubs remain empty — loaders never invent them.
    public static func makeCatalog(
        using loaders: AgentExtensionHermesLoaders
    ) -> AgentExtensionCatalog {
        makeCatalog(
            hermesPlugins: loaders.loadPlugins(),
            hermesSkills: loaders.loadSkills(),
            hermesMCPServers: loaders.loadMCPServers()
        )
    }

    /// Read-only production factory over an installed Hermes home.
    public static func makeCatalog(
        fromHermesHome context: ServerContext,
        transport: (any ServerTransport)? = nil
    ) -> AgentExtensionCatalog {
        let xport = transport ?? context.makeTransport()
        return makeCatalog(using: .installed(context: context, transport: xport))
    }

    /// Lightweight MCP roster from `config.yaml` for catalog use.
    ///
    /// Read-only: absent / empty `mcp_servers` → `[]`. Does not invent
    /// servers. Transport follows Hermes (`url` present ⇒ http/sse, else stdio).
    public static func hermesMCPServers(fromConfigYAML yaml: String) -> [HermesMCPServer] {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let parsed = HermesYAML.parseNestedYAML(yaml)

        var serverNames: Set<String> = []
        for key in parsed.values.keys where key.hasPrefix("mcp_servers.") {
            let rest = key.dropFirst("mcp_servers.".count)
            guard let first = rest.split(separator: ".").first else { continue }
            serverNames.insert(String(first))
        }
        for key in parsed.lists.keys where key.hasPrefix("mcp_servers.") {
            let rest = key.dropFirst("mcp_servers.".count)
            guard let first = rest.split(separator: ".").first, rest.contains(".") else { continue }
            serverNames.insert(String(first))
        }
        // A bare `mcp_servers:` with only nested maps still yields value keys;
        // maps alone under `mcp_servers` without children are not servers.
        guard !serverNames.isEmpty else { return [] }

        return serverNames.sorted().map { name in
            let prefix = "mcp_servers.\(name)"
            let url = parsed.values["\(prefix).url"].map(HermesYAML.stripYAMLQuotes)
            let command = parsed.values["\(prefix).command"].map(HermesYAML.stripYAMLQuotes)
            let transportRaw = parsed.values["\(prefix).transport"]
                .map(HermesYAML.stripYAMLQuotes)
            let enabledRaw = parsed.values["\(prefix).enabled"]
                .map(HermesYAML.stripYAMLQuotes)
            let enabled = enabledRaw.flatMap(BotAgentConfigService.parseBool) ?? true
            let transport: MCPTransport = {
                guard url != nil else { return .stdio }
                return transportRaw == "sse" ? .sse : .http
            }()
            let args = (parsed.lists["\(prefix).args"] ?? []).map(HermesYAML.stripYAMLQuotes)

            return HermesMCPServer(
                name: name,
                transport: transport,
                command: command,
                args: args,
                url: url,
                auth: parsed.values["\(prefix).auth"].map(HermesYAML.stripYAMLQuotes),
                env: [:],
                headers: [:],
                timeout: nil,
                connectTimeout: nil,
                enabled: enabled,
                toolsInclude: [],
                toolsExclude: [],
                resourcesEnabled: false,
                promptsEnabled: false,
                hasOAuthToken: false
            )
        }
    }

    /// `skills.disabled` names from config.yaml (global list only).
    static func disabledSkillNames(fromConfigYAML yaml: String) -> Set<String> {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let parsed = HermesYAML.parseNestedYAML(yaml)
        var disabled = Set(parsed.lists["skills.disabled"] ?? [])
        if disabled.isEmpty, let inline = parsed.values["skills.disabled"] {
            let trimmed = inline.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                disabled = Set(
                    HermesYAML.parseFlatFlowList(String(trimmed.dropFirst().dropLast()))
                )
            }
        }
        return Set(disabled.filter { !$0.isEmpty }.map(HermesYAML.stripYAMLQuotes))
    }
}
