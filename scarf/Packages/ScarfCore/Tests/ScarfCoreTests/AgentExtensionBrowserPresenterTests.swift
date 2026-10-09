import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent extension browser presenter")
struct AgentExtensionBrowserPresenterTests {

    private let hermesCaps = AgentSlashHintPresenter.defaultCapabilities(for: .hermes)
    private let claudeCaps = AgentSlashHintPresenter.defaultCapabilities(for: .claudeCode)

    @Test("Hermes fixtures group into plugin, skill, and MCP sections")
    func hermesFixturesGroupByKind() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "web",
                description: "Web plugin",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .available,
                version: "1.0"
            ),
            AgentExtensionDescriptor(
                name: "git",
                description: "Git skill",
                kind: .hermesSkill,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .disabled,
                requiredCapabilities: [.skills],
                category: "vcs"
            ),
            AgentExtensionDescriptor(
                name: "docs",
                description: "MCP docs",
                kind: .mcpServer,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .notEnabled,
                requiredCapabilities: [.mcp]
            ),
            AgentExtensionDescriptor(
                name: "claude-only",
                description: "Should not appear for Hermes",
                kind: .claudeCodeSkill,
                source: .claudeCode,
                backendScope: .backends([.claudeCode]),
                availability: .available,
                requiredCapabilities: [.skills]
            ),
        ])

        let presentation = AgentExtensionBrowserPresenter.make(
            catalog: catalog,
            backendID: .hermes,
            capabilities: hermesCaps
        )

        #expect(presentation.sections.map(\.kind) == [.hermesPlugin, .hermesSkill, .mcpServer])
        #expect(presentation.sections[0].rows.map(\.name) == ["web"])
        #expect(presentation.sections[0].rows[0].availabilityLabel == "Available")
        #expect(presentation.sections[1].rows.map(\.name) == ["git"])
        #expect(presentation.sections[1].rows[0].availabilityLabel == "Disabled")
        #expect(presentation.sections[2].rows.map(\.name) == ["docs"])
        #expect(presentation.sections[2].rows[0].availabilityLabel == "Not enabled")
        #expect(!presentation.isEmpty)
    }

    @Test("disabled and not-enabled entries stay visible")
    func disabledAndNotEnabledStayVisible() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "off",
                description: "Disabled plugin",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .disabled
            ),
            AgentExtensionDescriptor(
                name: "parked",
                description: "Not enabled plugin",
                kind: .hermesPlugin,
                source: .hermes,
                backendScope: .backends([.hermes]),
                availability: .notEnabled
            ),
        ])

        let presentation = AgentExtensionBrowserPresenter.make(
            catalog: catalog,
            backendID: .hermes,
            capabilities: hermesCaps
        )

        #expect(presentation.sections.count == 1)
        #expect(presentation.sections[0].rows.map(\.name) == ["off", "parked"])
        #expect(presentation.sections[0].rows.map(\.availabilityLabel) == ["Disabled", "Not enabled"])
    }

    @Test("Claude capabilities yield an empty Claude-skills section")
    func claudeYieldsEmptySkillsSection() {
        let presentation = AgentExtensionBrowserPresenter.make(
            catalog: AgentExtensionCatalogs.makeCatalog(),
            backendID: .claudeCode,
            capabilities: claudeCaps
        )

        #expect(presentation.backendID == .claudeCode)
        #expect(presentation.sections.map(\.kind) == [.claudeCodeSkill])
        #expect(presentation.sections[0].rows.isEmpty)
        #expect(presentation.sections[0].isExplicitlyEmpty)
        #expect(presentation.isEmpty)
        #expect(presentation.emptyMessage.contains("Claude"))
    }

    @Test("unknown availability keeps its label")
    func unknownAvailabilityLabel() {
        let catalog = AgentExtensionCatalog(entries: [
            AgentExtensionDescriptor(
                name: "stub",
                description: "Unverified",
                kind: .scarfLocal,
                source: .scarfLocal,
                backendScope: .scarfLocal,
                availability: .unknown
            ),
        ])

        let presentation = AgentExtensionBrowserPresenter.make(
            catalog: catalog,
            backendID: .claudeCode,
            capabilities: claudeCaps
        )

        let scarf = presentation.sections.first { $0.kind == .scarfLocal }
        #expect(scarf?.rows.map(\.availabilityLabel) == ["Unknown"])
    }
}
