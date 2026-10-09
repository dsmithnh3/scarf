import Testing
import Foundation
@testable import ScarfCore

/// Production factory: read-only Hermes loaders → ``AgentExtensionCatalog``.
///
/// Temp Hermes homes exercise the real scanners; injectable loaders cover
/// the seam without inventing Claude skills.
@Suite("Agent extension catalog Hermes loaders")
struct AgentExtensionCatalogHermesLoaderTests {

    private static func scratchHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ext-cat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func put(_ relative: String, in home: URL, _ text: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("production factory surfaces Hermes plugins skills and MCP from installed home")
    func productionFactorySurfacesInstalledHermesExtensions() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.put(
            "plugins/browser/plugin.yaml",
            in: home,
            "name: browser\nversion: 0.3.1\nsource: user\n"
        )
        try Self.put(
            "skills/ops/deploy/SKILL.md",
            in: home,
            "---\nname: deploy\ndescription: Deploy helpers\n---\n# deploy\n"
        )
        try Self.put(
            "config.yaml",
            in: home,
            """
            plugins:
              enabled:
              - browser
            skills:
              disabled: []
            mcp_servers:
              filesystem:
                command: npx
                args:
                - -y
                - "@modelcontextprotocol/server-filesystem"
                enabled: true
              remote-docs:
                url: https://example.test/mcp
                transport: http
                enabled: false
            """
        )

        let context = ServerContext.local(home: home)
        let catalog = AgentExtensionCatalogs.makeCatalog(
            fromHermesHome: context,
            transport: LocalTransport()
        )

        let hermes = catalog.matching(
            backendID: .hermes,
            capabilities: [.skills, .mcp]
        )
        #expect(Set(hermes.map(\.kind)) == [.hermesPlugin, .hermesSkill, .mcpServer])
        #expect(hermes.map(\.name).sorted() == ["browser", "deploy", "filesystem", "remote-docs"])

        let browser = try #require(hermes.first { $0.id == "hermesPlugin:browser" })
        #expect(browser.availability == .available)
        #expect(browser.version == "0.3.1")

        let deploy = try #require(hermes.first { $0.id == "hermesSkill:deploy" })
        #expect(deploy.availability == .available)
        #expect(deploy.category == "ops")
        #expect(deploy.requiredCapabilities == [.skills])

        let filesystem = try #require(hermes.first { $0.id == "mcpServer:filesystem" })
        #expect(filesystem.availability == .available)
        #expect(filesystem.description.contains("stdio"))

        let remote = try #require(hermes.first { $0.id == "mcpServer:remote-docs" })
        #expect(remote.availability == .disabled)

        let claude = catalog.matching(
            backendID: .claudeCode,
            capabilities: [.skills, .mcp]
        )
        #expect(claude.isEmpty)
        #expect(catalog.entries.filter { $0.kind == .claudeCodeSkill }.isEmpty)
    }

    @Test("production factory keeps Claude empty when Hermes home has no extensions")
    func emptyHermesHomeYieldsEmptyCatalogWithoutClaudeInvention() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("plugins"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("skills"),
            withIntermediateDirectories: true
        )

        let catalog = AgentExtensionCatalogs.makeCatalog(
            fromHermesHome: ServerContext.local(home: home),
            transport: LocalTransport()
        )
        #expect(catalog.entries.isEmpty)
        #expect(AgentExtensionCatalogs.claudeCodeSkills.isEmpty)
    }

    @Test("injectable loaders feed makeCatalog without inventing Claude skills")
    func injectableLoadersSurfaceHermesOnly() {
        let loaders = AgentExtensionHermesLoaders(
            loadPlugins: {
                [
                    HermesPluginListEntry(
                        name: "injected-plugin",
                        status: .enabled,
                        version: "1.0.0",
                        description: "Injected",
                        source: "test"
                    ),
                ]
            },
            loadSkills: {
                [
                    HermesSkill(
                        id: "cat/injected-skill",
                        name: "injected-skill",
                        category: "cat",
                        path: "/tmp/injected-skill",
                        files: ["SKILL.md"],
                        requiredConfig: [],
                        enabled: true
                    ),
                ]
            },
            loadMCPServers: {
                [
                    HermesMCPServer(
                        name: "injected-mcp",
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
            }
        )

        let catalog = AgentExtensionCatalogs.makeCatalog(using: loaders)
        let hermes = catalog.matching(
            backendID: .hermes,
            capabilities: [.skills, .mcp]
        )
        #expect(hermes.map(\.name).sorted() == [
            "injected-mcp",
            "injected-plugin",
            "injected-skill",
        ])
        #expect(catalog.matching(backendID: .claudeCode, capabilities: [.skills]).isEmpty)
        #expect(catalog.entries.filter { $0.kind == .claudeCodeSkill }.isEmpty)
    }

    @Test("config YAML MCP reader maps enablement and transport without inventing servers")
    func configYAMLMCPReaderIsReadOnly() throws {
        let yaml = """
        mcp_servers:
          local-fs:
            command: npx
            enabled: true
          docs:
            url: https://docs.example/mcp
            transport: sse
            enabled: no
        """
        let servers = AgentExtensionCatalogs.hermesMCPServers(fromConfigYAML: yaml)
        #expect(servers.map(\.name) == ["docs", "local-fs"])
        let local = try #require(servers.first { $0.name == "local-fs" })
        #expect(local.transport == .stdio)
        #expect(local.command == "npx")
        #expect(local.enabled == true)
        let docs = try #require(servers.first { $0.name == "docs" })
        #expect(docs.transport == .sse)
        #expect(docs.enabled == false)
        #expect(AgentExtensionCatalogs.hermesMCPServers(fromConfigYAML: "").isEmpty)
        #expect(AgentExtensionCatalogs.hermesMCPServers(fromConfigYAML: "model:\n  default: x\n").isEmpty)
    }

    @Test("disabled skill from config surfaces as disabled availability")
    func disabledSkillFromConfigSurfacesDisabled() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put(
            "skills/ops/deploy/SKILL.md",
            in: home,
            "---\nname: deploy\ndescription: d\n---\n# deploy\n"
        )
        try Self.put(
            "config.yaml",
            in: home,
            """
            skills:
              disabled:
              - deploy
            """
        )

        let catalog = AgentExtensionCatalogs.makeCatalog(
            fromHermesHome: ServerContext.local(home: home),
            transport: LocalTransport()
        )
        let deploy = try #require(
            catalog.entries.first { $0.id == "hermesSkill:deploy" }
        )
        #expect(deploy.availability == .disabled)
    }
}
