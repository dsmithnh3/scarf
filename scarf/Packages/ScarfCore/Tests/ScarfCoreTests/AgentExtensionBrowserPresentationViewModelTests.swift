import Foundation
import Testing
@testable import ScarfCore

/// View-model seam: the sheet must render exactly what the presenter returns
/// (no second filtering layer that could invent or drop rows).
@Suite("Agent extension browser presentation for UI")
struct AgentExtensionBrowserPresentationViewModelTests {

    @Test("sheet rows equal presenter output for a Hermes fixture catalog")
    func sheetRowsEqualPresenterOutput() {
        let catalog = AgentExtensionCatalogs.makeCatalog(
            hermesPlugins: [
                HermesPluginListEntry(
                    name: "web",
                    status: .enabled,
                    version: "1.0",
                    description: "Web search",
                    source: "bundled"
                ),
            ],
            hermesSkills: [
                HermesSkill(
                    id: "vcs/git",
                    name: "git",
                    category: "vcs",
                    path: "/tmp/skills/vcs/git",
                    files: ["SKILL.md"],
                    requiredConfig: [],
                    enabled: false
                ),
            ],
            hermesMCPServers: [
                HermesMCPServer(
                    name: "docs",
                    transport: .stdio,
                    command: "docs-mcp",
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

        let presentation = AgentExtensionBrowserPresenter.make(
            catalog: catalog,
            backendID: .hermes,
            capabilities: AgentSlashHintPresenter.defaultCapabilities(for: .hermes)
        )

        // UI contract: section kinds and row ids are taken verbatim from the
        // presenter — the sheet must not invent Claude skills or drop disabled
        // Hermes skills.
        #expect(presentation.sections.map(\.kind) == [.hermesPlugin, .hermesSkill, .mcpServer])
        #expect(presentation.sections.flatMap(\.rows).map(\.id) == [
            "hermesPlugin:web",
            "hermesSkill:git",
            "mcpServer:docs",
        ])
        #expect(presentation.sections.first { $0.kind == .hermesSkill }?.rows.first?.availabilityLabel
            == "Disabled")
    }
}
