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
            // Name must not share the "st" prefix or the alias query also hits it.
            AgentSlashCommandDescriptor(
                name: "nudge",
                description: "Nudge the turn",
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
            query: "nud",
            backendID: .hermes,
            capabilities: []
        )

        #expect(byAlias.map(\.name) == ["status"])
        #expect(byPrefix.map(\.name) == ["nudge"])
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
            category: "session",
            source: .hermes
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentSlashCommandDescriptor.self, from: encoded)

        #expect(decoded == original)
    }

    @Test("Scarf-local catalog ships bundled scarf-* commands as local execution")
    func scarfLocalCatalogShipsBundledCommands() {
        let names = AgentSlashCommandCatalogs.scarfLocal.map(\.name).sorted()
        #expect(names == [
            "scarf-cron",
            "scarf-dashboard",
            "scarf-export",
            "scarf-help",
            "scarf-new",
            "scarf-widget",
        ])
        #expect(AgentSlashCommandCatalogs.scarfLocal.allSatisfy {
            $0.source == .scarfLocal && $0.execution == .local && $0.backendScope == .scarfLocal
        })
    }

    @Test("Hermes catalog matches ACP always-available truth and omits CLI-only names")
    func hermesCatalogMatchesACPTruth() {
        let compress = AgentSlashCommandCatalogs.hermes(preferCompressSpelling: true)
        let compact = AgentSlashCommandCatalogs.hermes(preferCompressSpelling: false)

        #expect(compress.map(\.name).contains("compress"))
        #expect(!compress.map(\.name).contains("compact"))
        #expect(compact.map(\.name).contains("compact"))
        #expect(!compact.map(\.name).contains("compress"))

        let names = Set(compress.map(\.name))
        #expect(names.isSuperset(of: [
            "help", "model", "tools", "context", "reset", "version", "steer", "queue", "title",
        ]))
        #expect(names.isDisjoint(with: ["clear", "cost", "yolo", "sessions", "codex-runtime", "reload-skills"]))
        #expect(compress.allSatisfy { $0.source == .hermes })
        #expect(compress.first { $0.name == "title" }?.execution == .local)
        #expect(compress.first { $0.name == "help" }?.execution == .forwardToBackend)
        #expect(compress.first { $0.name == "steer" }?.backendScope == .backends([.hermes]))
    }

    @Test("Claude catalog stub does not advertise unverified or permissions commands")
    func claudeCatalogStubStaysTruthful() {
        let commands = AgentSlashCommandCatalogs.claudeCode
        #expect(commands.isEmpty)
        #expect(!commands.map(\.name).contains("permissions"))
    }

    @Test("default registry merges Scarf then Hermes then Claude with first-wins")
    func defaultRegistryMergesCatalogsFirstWins() {
        let registry = AgentSlashCommandCatalogs.makeRegistry(hermesPreferCompressSpelling: true)
        let hermesCaps: AgentCapabilities = [
            .streaming, .sessions, .resume, .mcp, .skills, .memory, .cron, .toolCalls,
        ]
        let hermesHints = registry.hints(
            matching: "",
            backendID: .hermes,
            capabilities: hermesCaps
        )
        let claudeHints = registry.hints(
            matching: "",
            backendID: .claudeCode,
            capabilities: [.streaming, .sessions, .resume, .mcp, .toolCalls]
        )

        #expect(hermesHints.map(\.name).contains("scarf-help"))
        #expect(hermesHints.map(\.name).contains("compress"))
        #expect(hermesHints.map(\.name).contains("steer"))
        #expect(!hermesHints.map(\.name).contains("clear"))

        #expect(claudeHints.map(\.name).contains("scarf-help"))
        #expect(!claudeHints.map(\.name).contains("compress"))
        #expect(!claudeHints.map(\.name).contains("steer"))
        #expect(!claudeHints.map(\.name).contains("permissions"))
        #expect(claudeHints.allSatisfy { $0.source == .scarfLocal })
    }

    @Test("hints filter by prefix and format insertion text")
    func hintsFilterAndFormatInsertionText() {
        let registry = AgentSlashCommandCatalogs.makeRegistry(hermesPreferCompressSpelling: true)
        let hints = registry.hints(
            matching: "scarf-h",
            backendID: .hermes,
            capabilities: [.streaming, .sessions, .cron]
        )

        #expect(hints.map(\.name) == ["scarf-help"])
        #expect(hints[0].slashName == "/scarf-help")
        #expect(hints[0].insertionText == "/scarf-help")
        #expect(hints[0].source == .scarfLocal)

        let withArg = registry.hints(
            matching: "scarf-c",
            backendID: .hermes,
            capabilities: [.streaming, .sessions, .cron]
        ).first { $0.name == "scarf-cron" }
        #expect(withArg?.insertionText == "/scarf-cron ")
        #expect(withArg?.argumentHint != nil)
    }

    @Test("ACP discovery parses verified available_commands_update shape")
    func acpDiscoveryParsesVerifiedPayloadShape() {
        let parsed = AgentSlashCommandACPDiscovery.descriptors(fromACPCommands: [
            ["name": "/help", "description": "List available commands"],
            [
                "name": "steer",
                "description": "Inject guidance",
                "input": ["hint": "<guidance>"],
            ],
            ["description": "missing name is skipped"],
            ["name": "   ", "description": "blank name skipped"],
            ["name": "version", "description": "Show Hermes version"],
        ])

        #expect(parsed.map(\.name) == ["help", "steer", "version"])
        #expect(parsed[0].description == "List available commands")
        #expect(parsed[0].argumentHint == nil)
        #expect(parsed[0].source == .hermes)
        #expect(parsed[0].backendScope == .backends([.hermes]))
        #expect(parsed[0].execution == .forwardToBackend)
        #expect(parsed[1].argumentHint == "<guidance>")
        #expect(parsed.allSatisfy { $0.source == .hermes })
    }

    @Test("live Hermes ACP commands supersede static Hermes fallbacks and keep Scarf-local")
    func liveHermesACPCommandsSupersedeStaticFallbacks() {
        let base = AgentSlashCommandCatalogs.makeRegistry(hermesPreferCompressSpelling: true)
        let live = AgentSlashCommandACPDiscovery.descriptors(fromACPCommands: [
            ["name": "help", "description": "ACP help description"],
            ["name": "version", "description": "ACP version description"],
            ["name": "compress", "description": "ACP compress description"],
        ])

        let merged = base.mergingLiveHermesACPCommands(live)
        let hermesCaps: AgentCapabilities = [
            .streaming, .sessions, .resume, .mcp, .skills, .memory, .cron, .toolCalls,
        ]
        let hints = merged.hints(
            matching: "",
            backendID: .hermes,
            capabilities: hermesCaps
        )

        #expect(hints.map(\.name).contains("scarf-help"))
        #expect(hints.first { $0.name == "help" }?.description == "ACP help description")
        #expect(hints.filter { $0.name == "help" }.count == 1)
        #expect(hints.filter { $0.name == "version" }.count == 1)
        #expect(hints.filter { $0.name == "compress" }.count == 1)
        // Static Hermes names not in the live advertisement remain as fallback
        // (ACP does not always re-emit after session/load).
        #expect(hints.map(\.name).contains("title"))
        #expect(hints.map(\.name).contains("steer"))
        #expect(hints.map(\.name).contains("queue"))

        let claudeHints = merged.hints(
            matching: "",
            backendID: .claudeCode,
            capabilities: [.streaming, .sessions, .resume, .mcp, .toolCalls]
        )
        #expect(claudeHints.allSatisfy { $0.source == .scarfLocal })
        #expect(!claudeHints.map(\.name).contains("help"))
    }
}
