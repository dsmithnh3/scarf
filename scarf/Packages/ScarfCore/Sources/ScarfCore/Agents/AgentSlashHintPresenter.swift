import Foundation

/// Snapshot a Scarf-native slash menu can render from composer draft text.
///
/// Visibility matches Hermes chat (`RichChatViewModel.shouldShowSlashMenu`):
/// show only while the draft is a single `/token` with no whitespace. Filtering
/// is delegated to ``AgentSlashCommandRegistry.hints`` so backend scope and
/// capability gates stay truthful (Claude catalog stays empty; permissions stay
/// unadvertised).
public struct AgentSlashHintPresentation: Equatable, Sendable {
    public var isVisible: Bool
    public var query: String
    public var hints: [AgentSlashCommandHint]
    /// True when the active backend+capabilities expose zero commands at all
    /// (distinct from "filter matched nothing").
    public var catalogIsEmpty: Bool

    public init(
        isVisible: Bool,
        query: String,
        hints: [AgentSlashCommandHint],
        catalogIsEmpty: Bool
    ) {
        self.isVisible = isVisible
        self.query = query
        self.hints = hints
        self.catalogIsEmpty = catalogIsEmpty
    }
}

/// ViewModel-facing presenter that turns composer draft text into backend-aware
/// Scarf-native slash hints. Pure ScarfCore — no SwiftUI / CLUI styling.
public struct AgentSlashHintPresenter: Sendable, Equatable {
    public var registry: AgentSlashCommandRegistry
    public var backendID: AgentID
    public var capabilities: AgentCapabilities

    public init(
        registry: AgentSlashCommandRegistry = AgentSlashCommandCatalogs.makeRegistry(),
        backendID: AgentID,
        capabilities: AgentCapabilities
    ) {
        self.registry = registry
        self.backendID = backendID
        self.capabilities = capabilities
    }

    /// Capability sets that mirror the production Hermes / Claude backends
    /// without inventing unsupported flags (Claude omits `.permissions`).
    public static func defaultCapabilities(for backendID: AgentID) -> AgentCapabilities {
        switch backendID {
        case .hermes:
            return [
                .streaming,
                .reasoning,
                .toolCalls,
                .permissions,
                .sessions,
                .resume,
                .mcp,
                .skills,
                .usage,
                .shellCommands,
                .memory,
                .cron,
                .gateway,
                .proxy,
                .remoteExecution,
            ]
        case .claudeCode:
            return [
                .streaming,
                .reasoning,
                .toolCalls,
                .sessions,
                .resume,
                .mcp,
                .usage,
                .fileChanges,
                .shellCommands,
            ]
        default:
            return [.streaming, .sessions]
        }
    }

    public static func shouldShowMenu(draft: String) -> Bool {
        guard draft.hasPrefix("/") else { return false }
        return !draft.contains(" ") && !draft.contains("\n")
    }

    public static func menuQuery(draft: String) -> String {
        guard draft.hasPrefix("/") else { return "" }
        return String(draft.dropFirst())
    }

    public func presentation(for draft: String) -> AgentSlashHintPresentation {
        let catalogIsEmpty = registry.availableCommands(
            backendID: backendID,
            capabilities: capabilities
        ).isEmpty

        guard Self.shouldShowMenu(draft: draft) else {
            return AgentSlashHintPresentation(
                isVisible: false,
                query: "",
                hints: [],
                catalogIsEmpty: catalogIsEmpty
            )
        }

        let query = Self.menuQuery(draft: draft)
        let hints = registry.hints(
            matching: query,
            backendID: backendID,
            capabilities: capabilities
        )
        return AgentSlashHintPresentation(
            isVisible: true,
            query: query,
            hints: hints,
            catalogIsEmpty: catalogIsEmpty
        )
    }

    /// Replace the slash token with the hint's insertion text. Returns `nil`
    /// when the draft is not currently in slash-menu mode.
    public func accepting(_ hint: AgentSlashCommandHint, draft: String) -> String? {
        guard Self.shouldShowMenu(draft: draft) else { return nil }
        return hint.insertionText
    }
}
