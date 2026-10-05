import Foundation

/// Origin catalog for a registered slash command.
///
/// Hints surface this so Scarf-native UI can badge Scarf-local vs backend
/// commands without importing CLUI/Opal styling.
public enum AgentSlashCommandCatalogSource: String, Codable, Equatable, Hashable, Sendable {
    case scarfLocal
    case hermes
    case claudeCode
}

/// Scarf-native suggestion row derived from an available registry command.
///
/// No composer UI yet — this is the query model a Scarf chat surface will
/// consume later.
public struct AgentSlashCommandHint: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }

    public var name: String
    public var description: String
    public var argumentHint: String?
    public var source: AgentSlashCommandCatalogSource
    public var execution: AgentSlashCommandExecution

    public init(
        name: String,
        description: String,
        argumentHint: String? = nil,
        source: AgentSlashCommandCatalogSource,
        execution: AgentSlashCommandExecution
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
        self.execution = execution
    }

    public var slashName: String { "/\(name)" }

    /// Text inserted when the user accepts a hint. Commands with an argument
    /// hint leave a trailing space so typing can continue immediately.
    public var insertionText: String {
        argumentHint == nil ? slashName : "\(slashName) "
    }
}

/// Static/discovered command catalogs for Scarf-local and backend scopes.
///
/// Rosters stay capability-truthful: Hermes entries mirror ACP always-available
/// commands documented against `RichChatViewModel.alwaysAvailableCommands` /
/// `nonInterruptiveCommands`. Claude Code returns an empty stub until Scarf
/// verifies a live slash-forwarding or discovery source (permissions stay
/// unadvertised).
public enum AgentSlashCommandCatalogs: Sendable {
    /// Bundled global `/scarf-*` prompt templates (local expansion).
    public static let scarfLocal: [AgentSlashCommandDescriptor] = [
        AgentSlashCommandDescriptor(
            name: "scarf-help",
            description: "Explain what Scarf can do — features, slash commands, and where to look",
            backendScope: .scarfLocal,
            execution: .local,
            category: "scarf",
            source: .scarfLocal
        ),
        AgentSlashCommandDescriptor(
            name: "scarf-dashboard",
            description: "Design or edit the active project's dashboard.json (widgets, layout, refresh)",
            backendScope: .scarfLocal,
            argumentHint: "<what to change>",
            execution: .local,
            category: "scarf",
            source: .scarfLocal
        ),
        AgentSlashCommandDescriptor(
            name: "scarf-cron",
            description: "Schedule a recurring Hermes cron job for the active project",
            backendScope: .scarfLocal,
            requiredCapabilities: [.cron],
            argumentHint: "<what the job should do>",
            execution: .local,
            category: "scarf",
            source: .scarfLocal
        ),
        AgentSlashCommandDescriptor(
            name: "scarf-export",
            description: "Prepare the active project for export as a .scarftemplate bundle",
            backendScope: .scarfLocal,
            execution: .local,
            category: "scarf",
            source: .scarfLocal
        ),
        AgentSlashCommandDescriptor(
            name: "scarf-new",
            description: "Create a brand-new Scarf project — invokes the scarf-template-author skill interview",
            backendScope: .scarfLocal,
            argumentHint: "<optional one-line description>",
            execution: .local,
            category: "scarf",
            source: .scarfLocal
        ),
        AgentSlashCommandDescriptor(
            name: "scarf-widget",
            description: "Add a single widget to the active project's dashboard",
            backendScope: .scarfLocal,
            argumentHint: "<widget type>",
            execution: .local,
            category: "scarf",
            source: .scarfLocal
        ),
    ]

    /// Hermes ACP always-available / non-interruptive roster.
    ///
    /// Omits CLI-only names (`clear`, `cost`, `yolo`, …) that fall through to
    /// the model over ACP. `preferCompressSpelling` mirrors
    /// `HermesCapabilities.hasACPCompressSpelling` (compress ≥ 0.19.1).
    public static func hermes(preferCompressSpelling: Bool = true) -> [AgentSlashCommandDescriptor] {
        let compressName = preferCompressSpelling ? "compress" : "compact"
        return [
            AgentSlashCommandDescriptor(
                name: "title",
                description: "Rename this chat",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                argumentHint: "<name>",
                execution: .local,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "help",
                description: "Show available commands",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "model",
                description: "Switch the active model",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                argumentHint: "[<model>]",
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "tools",
                description: "Manage tool availability",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions, .toolCalls],
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "context",
                description: "Show conversation message counts by role",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "reset",
                description: "Clear conversation history",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: compressName,
                description: "Compress the conversation history",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "version",
                description: "Show Hermes version",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "steer",
                description: "Nudge the agent mid-run (applies after the next tool call)",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                argumentHint: "<guidance>",
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
            AgentSlashCommandDescriptor(
                name: "queue",
                description: "Queue a prompt to run after the current turn",
                backendScope: .backends([.hermes]),
                requiredCapabilities: [.sessions],
                argumentHint: "<text>",
                execution: .forwardToBackend,
                category: "session",
                source: .hermes
            ),
        ]
    }

    /// Claude Code catalog stub.
    ///
    /// Empty until Scarf verifies a structured discovery path or that literal
    /// slash text is interpreted correctly through `ClaudeCodeBackend`'s
    /// stream-json channel. Do not invent CLI menus here; permissions remain
    /// unadvertised.
    public static let claudeCode: [AgentSlashCommandDescriptor] = []

    /// Production merge order: Scarf-local first (shadows backend duplicates),
    /// then Hermes, then Claude. Hermes remains the default backend route.
    public static func makeRegistry(
        hermesPreferCompressSpelling: Bool = true
    ) -> AgentSlashCommandRegistry {
        AgentSlashCommandRegistry(
            commands: scarfLocal
                + hermes(preferCompressSpelling: hermesPreferCompressSpelling)
                + claudeCode
        )
    }
}
