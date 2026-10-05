import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent extension catalog")
struct AgentExtensionCatalogTests {

    // MARK: - Entry shape / filtering

    @Test("catalog entries carry kind, source, backend scope, and availability")
    func entriesCarryKindSourceScopeAndAvailability() {
        let entry = AgentExtensionDescriptor(
            name: "web-search",
            description: "Hermes web search plugin",
            kind: .hermesPlugin,
            source: .hermes,
            backendScope: .backends([.hermes]),
            availability: .available,
            version: "1.2.0",
            category: "tools"
        )

        #expect(entry.id == "hermesPlugin:web-search")
        #expect(entry.kind == .hermesPlugin)
        #expect(entry.source == .hermes)
        #expect(entry.backendScope == .backends([.hermes]))
        #expect(entry.availability == .available)
        #expect(entry.version == "1.2.0")
        #expect(entry.category == "tools")
    }

    @Test("same name under different kinds stay distinct catalog entries")
    func sameNameUnderDifferentKindsStayDistinct() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "git",
                description: "Hermes git skill",
                kind: .hermesSkill,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available,
                requiredCapabilities: [.skills]
            ),
            AgentExtensionDescriptor(
                name: "git",
                description: "Hermes git plugin",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available
            ),
        ])

        let hermes = catalog.matching(backendID: .hermes, capabilities: [.skills])
        #expect(hermes.map(\.id) == ["hermesSkill:git", "hermesPlugin:git"])
        #expect(Set(hermes.map(\.kind)) == [.hermesSkill, .hermesPlugin])
    }

    @Test("backend-scoped entries hide for other backends")
    func backendScopedEntriesHideForOtherBackends() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "memory",
                description: "Hermes memory skill",
                kind: .hermesSkill,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available,
                requiredCapabilities: [.skills]
            ),
            AgentExtensionDescriptor(
                name: "project-docs",
                description: "Claude project skill",
                kind: .claudeCodeSkill,
                source: .claudeCode,
                backendScope: .backends([.claudeCode]),
                availability: .available,
                requiredCapabilities: [.skills]
            ),
            AgentExtensionDescriptor(
                name: "scarf-helper",
                description: "Scarf-local helper",
                kind: .scarfLocal,
                source: .scarfLocal,
                backendScope: .scarfLocal,
                availability: .available
            ),
        ])

        let hermes = catalog.matching(
            backendID: .hermes,
            capabilities: [.skills]
        )
        let claude = catalog.matching(
            backendID: .claudeCode,
            capabilities: [.skills]
        )

        #expect(hermes.map(\.name) == ["memory", "scarf-helper"])
        #expect(claude.map(\.name) == ["project-docs", "scarf-helper"])
    }

    @Test("capability-gated entries hide when capability is missing")
    func capabilityGatedEntriesHideWhenMissing() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "filesystem",
                description: "Hermes filesystem MCP",
                kind: .mcpServer,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available,
                requiredCapabilities: [.mcp]
            ),
            AgentExtensionDescriptor(
                name: "summarize",
                description: "Hermes summarize skill",
                kind: .hermesSkill,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available,
                requiredCapabilities: [.skills]
            ),
        ])

        let withoutCaps = catalog.matching(
            backendID: .hermes,
            capabilities: [.streaming, .sessions]
        )
        let withMCP = catalog.matching(
            backendID: .hermes,
            capabilities: [.streaming, .sessions, .mcp]
        )
        let withBoth = catalog.matching(
            backendID: .hermes,
            capabilities: [.streaming, .sessions, .mcp, .skills]
        )

        #expect(withoutCaps.isEmpty)
        #expect(withMCP.map(\.name) == ["filesystem"])
        #expect(withBoth.map(\.name) == ["filesystem", "summarize"])
    }

    @Test("availability filter keeps disabled and notEnabled when requested")
    func availabilityFilterKeepsDisabledAndNotEnabled() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "live",
                description: "Enabled plugin",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available
            ),
            AgentExtensionDescriptor(
                name: "off",
                description: "Disabled plugin",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .disabled
            ),
            AgentExtensionDescriptor(
                name: "inert",
                description: "Installed but not enabled",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .notEnabled
            ),
        ])

        let activeOnly = catalog.matching(
            backendID: .hermes,
            capabilities: [],
            availability: [.available]
        )
        let inactive = catalog.matching(
            backendID: .hermes,
            capabilities: [],
            availability: [.disabled, .notEnabled]
        )

        #expect(activeOnly.map(\.name) == ["live"])
        #expect(inactive.map(\.name) == ["off", "inert"])
    }

    @Test("kind filter returns only requested extension kinds")
    func kindFilterReturnsOnlyRequestedKinds() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "plug",
                description: "plugin",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available
            ),
            AgentExtensionDescriptor(
                name: "skill",
                description: "skill",
                kind: .hermesSkill,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available,
                requiredCapabilities: [.skills]
            ),
            AgentExtensionDescriptor(
                name: "mcp",
                description: "mcp",
                kind: .mcpServer,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available,
                requiredCapabilities: [.mcp]
            ),
        ])

        let skillsOnly = catalog.matching(
            backendID: .hermes,
            capabilities: [.skills, .mcp],
            kinds: [.hermesSkill]
        )
        #expect(skillsOnly.map(\.name) == ["skill"])
    }

    @Test("catalog dedupes by composite id preferring first registration")
    func catalogDedupesByCompositeIdPreferringFirst() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "search",
                description: "first",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available
            ),
            AgentExtensionDescriptor(
                name: "search",
                description: "duplicate",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .disabled
            ),
        ])

        #expect(catalog.entries.count == 1)
        #expect(catalog.entries[0].description == "first")
        #expect(catalog.entries[0].availability == .available)
    }

    // MARK: - Source adapters / stubs

    @Test("Hermes plugin adapter maps list fixtures without inventing rows")
    func hermesPluginAdapterMapsListFixtures() {
        let fixtures = [
            HermesPluginListEntry(
                name: "browser",
                status: .enabled,
                version: "0.3.1",
                description: "Browser tools",
                source: "user"
            ),
            HermesPluginListEntry(
                name: "legacy",
                status: .notEnabled,
                version: "0.1.0",
                description: "Installed but inert",
                source: "bundled"
            ),
            HermesPluginListEntry(
                name: "old-tool",
                status: .disabled,
                version: "0.0.9",
                description: "User-disabled",
                source: "user"
            ),
        ]

        let entries = AgentExtensionCatalogs.hermesPlugins(from: fixtures)

        #expect(entries.map(\.id) == [
            "hermesPlugin:browser",
            "hermesPlugin:legacy",
            "hermesPlugin:old-tool",
        ])
        #expect(entries.map(\.availability) == [.available, .notEnabled, .disabled])
        #expect(entries.allSatisfy { $0.kind == .hermesPlugin && $0.source == .hermes })
        #expect(entries.allSatisfy {
            if case .backends(let ids) = $0.backendScope { return ids == [.hermes] }
            return false
        })
        #expect(entries[0].version == "0.3.1")
        #expect(AgentExtensionCatalogs.hermesPlugins(from: []).isEmpty)
    }

    @Test("Hermes skill adapter maps skill fixtures with skills capability")
    func hermesSkillAdapterMapsSkillFixtures() {
        let fixtures = [
            HermesSkill(
                id: "ops/deploy",
                name: "deploy",
                category: "ops",
                path: "/tmp/skills/ops/deploy",
                files: ["SKILL.md"],
                requiredConfig: [],
                enabled: true
            ),
            HermesSkill(
                id: "ops/rollback",
                name: "rollback",
                category: "ops",
                path: "/tmp/skills/ops/rollback",
                files: ["SKILL.md"],
                requiredConfig: ["API_KEY"],
                enabled: false
            ),
        ]

        let entries = AgentExtensionCatalogs.hermesSkills(from: fixtures)

        #expect(entries.map(\.id) == ["hermesSkill:deploy", "hermesSkill:rollback"])
        #expect(entries.map(\.availability) == [.available, .disabled])
        #expect(entries.allSatisfy {
            $0.kind == .hermesSkill
                && $0.source == .hermes
                && $0.requiredCapabilities == [.skills]
        })
        #expect(entries[0].category == "ops")
        #expect(entries[0].path == "/tmp/skills/ops/deploy")
        #expect(AgentExtensionCatalogs.hermesSkills(from: []).isEmpty)
    }

    @Test("Hermes MCP adapter maps server fixtures with mcp capability")
    func hermesMCPAdapterMapsServerFixtures() {
        let fixtures = [
            HermesMCPServer(
                name: "filesystem",
                transport: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem"],
                url: nil,
                auth: nil,
                env: [:],
                headers: [:],
                timeout: nil,
                connectTimeout: nil,
                enabled: true,
                toolsInclude: [],
                toolsExclude: [],
                resourcesEnabled: false,
                promptsEnabled: false,
                hasOAuthToken: false
            ),
            HermesMCPServer(
                name: "remote-docs",
                transport: .http,
                command: nil,
                args: [],
                url: "https://example.test/mcp",
                auth: nil,
                env: [:],
                headers: [:],
                timeout: 30,
                connectTimeout: nil,
                enabled: false,
                toolsInclude: [],
                toolsExclude: [],
                resourcesEnabled: true,
                promptsEnabled: false,
                hasOAuthToken: false
            ),
        ]

        let entries = AgentExtensionCatalogs.hermesMCPServers(from: fixtures)

        #expect(entries.map(\.id) == ["mcpServer:filesystem", "mcpServer:remote-docs"])
        #expect(entries.map(\.availability) == [.available, .disabled])
        #expect(entries.allSatisfy {
            $0.kind == .mcpServer
                && $0.source == .hermes
                && $0.requiredCapabilities == [.mcp]
        })
        #expect(entries[0].description.contains("stdio"))
        #expect(AgentExtensionCatalogs.hermesMCPServers(from: []).isEmpty)
    }

    @Test("Claude Code skills stub stays empty until discovery is verified")
    func claudeCodeSkillsStubStaysEmpty() {
        #expect(AgentExtensionCatalogs.claudeCodeSkills.isEmpty)
    }

    @Test("Scarf-local extensions stub stays empty until one exists")
    func scarfLocalExtensionsStubStaysEmpty() {
        #expect(AgentExtensionCatalogs.scarfLocal.isEmpty)
    }

    @Test("makeCatalog merges Hermes fixtures and keeps Claude empty")
    func makeCatalogMergesHermesFixturesAndKeepsClaudeEmpty() {
        let plugins = [
            HermesPluginListEntry(
                name: "browser",
                status: .enabled,
                version: "1.0.0",
                description: "Browser",
                source: "user"
            ),
        ]
        let skills = [
            HermesSkill(
                id: "ops/deploy",
                name: "deploy",
                category: "ops",
                path: "/tmp/deploy",
                files: ["SKILL.md"],
                requiredConfig: [],
                enabled: true
            ),
        ]
        let mcp = [
            HermesMCPServer(
                name: "filesystem",
                transport: .stdio,
                command: "npx",
                args: [],
                url: nil,
                auth: nil,
                env: [:],
                headers: [:],
                timeout: nil,
                connectTimeout: nil,
                enabled: true,
                toolsInclude: [],
                toolsExclude: [],
                resourcesEnabled: false,
                promptsEnabled: false,
                hasOAuthToken: false
            ),
        ]

        let catalog = AgentExtensionCatalogs.makeCatalog(
            hermesPlugins: plugins,
            hermesSkills: skills,
            hermesMCPServers: mcp
        )

        let hermes = catalog.matching(
            backendID: .hermes,
            capabilities: [.skills, .mcp]
        )
        let claude = catalog.matching(
            backendID: .claudeCode,
            capabilities: [.skills, .mcp]
        )

        #expect(Set(hermes.map(\.kind)) == [.hermesPlugin, .hermesSkill, .mcpServer])
        #expect(hermes.map(\.name).sorted() == ["browser", "deploy", "filesystem"])
        // Claude sees no invented Claude skills; Hermes-scoped rows stay hidden.
        #expect(claude.isEmpty)

        let emptyDefault = AgentExtensionCatalogs.makeCatalog()
        #expect(emptyDefault.entries.isEmpty)
        #expect(emptyDefault.entries.filter { $0.kind == .claudeCodeSkill }.isEmpty)
    }

    @Test("kinds remain distinct — catalog does not collapse plugins skills and MCP")
    func kindsRemainDistinctAcrossSources() {
        let catalog = AgentExtensionCatalogs.makeCatalog(
            hermesPlugins: [
                HermesPluginListEntry(
                    name: "shared-name",
                    status: .enabled,
                    version: "1",
                    description: "plugin",
                    source: "user"
                ),
            ],
            hermesSkills: [
                HermesSkill(
                    id: "cat/shared-name",
                    name: "shared-name",
                    category: "cat",
                    path: "/tmp/shared-name",
                    files: ["SKILL.md"],
                    requiredConfig: [],
                    enabled: true
                ),
            ],
            hermesMCPServers: [
                HermesMCPServer(
                    name: "shared-name",
                    transport: .stdio,
                    command: "echo",
                    args: [],
                    url: nil,
                    auth: nil,
                    env: [:],
                    headers: [:],
                    timeout: nil,
                    connectTimeout: nil,
                    enabled: true,
                    toolsInclude: [],
                    toolsExclude: [],
                    resourcesEnabled: false,
                    promptsEnabled: false,
                    hasOAuthToken: false
                ),
            ]
        )

        let namesakes = catalog.matching(
            backendID: .hermes,
            capabilities: [.skills, .mcp]
        )
        #expect(namesakes.count == 3)
        #expect(Set(namesakes.map(\.kind)) == [.hermesPlugin, .hermesSkill, .mcpServer])
        #expect(Set(namesakes.map(\.id)) == [
            "hermesPlugin:shared-name",
            "hermesSkill:shared-name",
            "mcpServer:shared-name",
        ])
    }
}
