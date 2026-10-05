import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent slash command registry")
struct AgentSlashCommandRegistryTests {

    @Test("Scarf-local commands are available for every backend")
    func scarfLocalCommandsAreAvailableForEveryBackend() {
        let registry = AgentSlashCommandRegistry(commands: [
            AgentSlashCommandDescriptor(
                name: "new",
                description: "Start a new conversation",
                backendScope: .scarfLocal,
                execution: .local
            ),
        ])

        let hermes = registry.availableCommands(
            backendID: .hermes,
            capabilities: [.streaming, .sessions]
        )
        let claude = registry.availableCommands(
            backendID: .claudeCode,
            capabilities: [.streaming, .sessions, .resume]
        )

        #expect(hermes.map(\.name) == ["new"])
        #expect(claude.map(\.name) == ["new"])
    }

    @Test("backend-scoped commands hide for other backends")
    func backendScopedCommandsHideForOtherBackends() {
        let registry = AgentSlashCommandRegistry(commands: [
            AgentSlashCommandDescriptor(
                name: "compact",
                description: "Compact Hermes context",
                backendScope: .backends([.hermes]),
                execution: .forwardToBackend
            ),
            AgentSlashCommandDescriptor(
                name: "cost",
                description: "Show Claude usage",
                backendScope: .backends([.claudeCode]),
                execution: .forwardToBackend
            ),
        ])

        let hermes = registry.availableCommands(
            backendID: .hermes,
            capabilities: [.streaming]
        )
        let claude = registry.availableCommands(
            backendID: .claudeCode,
            capabilities: [.streaming]
        )

        #expect(hermes.map(\.name) == ["compact"])
        #expect(claude.map(\.name) == ["cost"])
    }

    @Test("capability-gated commands hide when capability is missing")
    func capabilityGatedCommandsHideWhenMissing() {
        let registry = AgentSlashCommandRegistry(commands: [
            AgentSlashCommandDescriptor(
                name: "mcp",
                description: "List MCP servers",
                backendScope: .backends([.hermes, .claudeCode]),
                requiredCapabilities: [.mcp],
                execution: .forwardToBackend
            ),
        ])

        let withoutMCP = registry.availableCommands(
            backendID: .hermes,
            capabilities: [.streaming, .sessions]
        )
        let withMCP = registry.availableCommands(
            backendID: .hermes,
            capabilities: [.streaming, .sessions, .mcp]
        )

        #expect(withoutMCP.isEmpty)
        #expect(withMCP.map(\.name) == ["mcp"])
    }

    @Test("registry merges sources and dedupes by name preferring first registration")
    func registryMergesAndDedupesByName() {
        let registry = AgentSlashCommandRegistry(commands: [
            AgentSlashCommandDescriptor(
                name: "help",
                description: "Scarf help",
                backendScope: .scarfLocal,
                execution: .local
            ),
            AgentSlashCommandDescriptor(
                name: "help",
                description: "Hermes help",
                backendScope: .backends([.hermes]),
                execution: .forwardToBackend
            ),
            AgentSlashCommandDescriptor(
                name: "status",
                description: "Show status",
                aliases: ["st"],
                backendScope: .scarfLocal,
                argumentHint: "[verbose]",
                execution: .local,
                category: "scarf"
            ),
        ])

        let available = registry.availableCommands(
            backendID: .hermes,
            capabilities: []
        )

        #expect(available.map(\.name) == ["help", "status"])
        #expect(available[0].description == "Scarf help")
        #expect(available[0].execution == .local)
        #expect(available[1].aliases == ["st"])
        #expect(available[1].argumentHint == "[verbose]")
        #expect(available[1].category == "scarf")
    }

    @Test("prefix filter is case-insensitive and matches aliases")
    func prefixFilterMatchesNameAndAliases() {
        let registry = AgentSlashCommandRegistry(commands: [
            AgentSlashCommandDescriptor(
                name: "status",
                description: "Show status",
                aliases: ["st"],
                backendScope: .scarfLocal,
                execution: .local
            ),
            AgentSlashCommandDescriptor(
                name: "steer",
                description: "Steer the turn",
                backendScope: .backends([.hermes]),
                execution: .forwardToBackend
            ),
        ])

        let byAlias = registry.matchingCommands(
            query: "ST",
            backendID: .hermes,
            capabilities: []
        )
        let byPrefix = registry.matchingCommands(
            query: "ste",
            backendID: .hermes,
            capabilities: []
        )

        #expect(byAlias.map(\.name) == ["status"])
        #expect(byPrefix.map(\.name) == ["steer"])
    }

    @Test("descriptor metadata round trips through Codable")
    func descriptorCodableRoundTrip() throws {
        let original = AgentSlashCommandDescriptor(
            name: "compact",
            description: "Compact context",
            aliases: ["c"],
            backendScope: .backends([.hermes]),
            requiredCapabilities: [.sessions, .memory],
            argumentHint: "[focus]",
            execution: .forwardToBackend,
            category: "session"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentSlashCommandDescriptor.self, from: encoded)

        #expect(decoded == original)
    }
}
