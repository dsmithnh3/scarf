import Foundation

/// One row in the read-only extensions browser.
public struct AgentExtensionBrowserRow: Identifiable, Equatable, Sendable {
    public var id: String { descriptor.id }
    public var descriptor: AgentExtensionDescriptor
    public var availabilityLabel: String

    public init(descriptor: AgentExtensionDescriptor) {
        self.descriptor = descriptor
        self.availabilityLabel = AgentExtensionBrowserPresenter.availabilityLabel(
            for: descriptor.availability
        )
    }

    public var name: String { descriptor.name }
    public var description: String { descriptor.description }
}

/// One kind-grouped section. Empty Claude-skills sections stay visible so the
/// UI can show an honest empty state instead of inventing rows.
public struct AgentExtensionBrowserSection: Identifiable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: AgentExtensionKind
    public var title: String
    public var rows: [AgentExtensionBrowserRow]
    /// True when this section is shown even though it has no rows (Claude
    /// skills stub). Other kinds omit empty sections.
    public var isExplicitlyEmpty: Bool

    public init(
        kind: AgentExtensionKind,
        title: String,
        rows: [AgentExtensionBrowserRow],
        isExplicitlyEmpty: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.rows = rows
        self.isExplicitlyEmpty = isExplicitlyEmpty
    }
}

/// Read-only presentation over ``AgentExtensionCatalog``.
///
/// No enable / disable / install / reload. Filtering is backend- and
/// capability-aware via ``AgentExtensionCatalog/matching(backendID:capabilities:kinds:availability:)``.
public struct AgentExtensionBrowserPresentation: Equatable, Sendable {
    public var backendID: AgentID
    public var sections: [AgentExtensionBrowserSection]
    public var emptyMessage: String

    public init(
        backendID: AgentID,
        sections: [AgentExtensionBrowserSection],
        emptyMessage: String
    ) {
        self.backendID = backendID
        self.sections = sections
        self.emptyMessage = emptyMessage
    }

    public var isEmpty: Bool {
        sections.allSatisfy(\.rows.isEmpty)
    }
}

/// Pure builder for the Scarf-native read-only extensions browser.
///
/// Shared by multi-agent project chat. Does not call Hermes loaders or
/// mutate config — callers supply an already-built catalog.
public enum AgentExtensionBrowserPresenter {
    /// Stable kind order for section headers.
    public static let sectionKindOrder: [AgentExtensionKind] = [
        .hermesPlugin,
        .hermesSkill,
        .claudeCodeSkill,
        .mcpServer,
        .scarfLocal,
    ]

    public static func make(
        catalog: AgentExtensionCatalog,
        backendID: AgentID,
        capabilities: AgentCapabilities
    ) -> AgentExtensionBrowserPresentation {
        let matched = catalog.matching(backendID: backendID, capabilities: capabilities)
        var byKind: [AgentExtensionKind: [AgentExtensionDescriptor]] = [:]
        for entry in matched {
            byKind[entry.kind, default: []].append(entry)
        }

        var sections: [AgentExtensionBrowserSection] = []
        for kind in sectionKindOrder {
            let entries = byKind[kind] ?? []
            if entries.isEmpty {
                // Claude skills stay an explicit empty section so the sheet
                // can say "no verified Claude skills" instead of inventing
                // rows. Other kinds omit empty sections.
                if kind == .claudeCodeSkill, backendID == .claudeCode {
                    sections.append(
                        AgentExtensionBrowserSection(
                            kind: kind,
                            title: kindTitle(kind),
                            rows: [],
                            isExplicitlyEmpty: true
                        )
                    )
                }
                continue
            }
            sections.append(
                AgentExtensionBrowserSection(
                    kind: kind,
                    title: kindTitle(kind),
                    rows: entries.map(AgentExtensionBrowserRow.init(descriptor:))
                )
            )
        }

        return AgentExtensionBrowserPresentation(
            backendID: backendID,
            sections: sections,
            emptyMessage: emptyMessage(for: backendID)
        )
    }

    public static func availabilityLabel(for availability: AgentExtensionAvailability) -> String {
        switch availability {
        case .available:
            return "Available"
        case .disabled:
            return "Disabled"
        case .notEnabled:
            return "Not enabled"
        case .unknown:
            return "Unknown"
        }
    }

    public static func kindTitle(_ kind: AgentExtensionKind) -> String {
        switch kind {
        case .hermesPlugin:
            return "Hermes plugins"
        case .hermesSkill:
            return "Hermes skills"
        case .claudeCodeSkill:
            return "Claude Code skills"
        case .mcpServer:
            return "MCP servers"
        case .scarfLocal:
            return "Scarf extensions"
        }
    }

    private static func emptyMessage(for backendID: AgentID) -> String {
        switch backendID {
        case .claudeCode:
            return "No verified Claude Code skills or Scarf-local extensions in this catalog yet."
        case .hermes:
            return "No Hermes plugins, skills, or MCP servers matched this backend."
        default:
            return "No extensions matched this backend."
        }
    }
}
