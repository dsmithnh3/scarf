import Foundation

/// Read-only probe fact used to build project default-agent options.
///
/// Mirrors installation/path/version diagnostics without depending on the
/// macOS `AgentRuntime` snapshot type. Auth and model discovery are out of
/// scope — callers must not invent model lists here.
public struct ProjectAgentBackendProbe: Equatable, Sendable {
    public let id: AgentID
    public let displayName: String
    public let executablePath: String?
    public let status: AgentInstallationStatus

    public init(
        id: AgentID,
        displayName: String,
        executablePath: String?,
        status: AgentInstallationStatus
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.status = status
    }
}

/// One selectable project default backend row.
public struct ProjectAgentPreferenceOption: Identifiable, Equatable, Sendable {
    public let id: AgentID
    public let displayName: String
    public let detail: String

    public init(id: AgentID, displayName: String, detail: String) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

/// Presentation for choosing a project's preferred agent runtime.
///
/// Hermes remains always selectable (compatibility default). Claude appears
/// only when diagnostics report `.available`. Hermes-only chat settings
/// (model presets, auto-accept edits) are gated by `showsHermesChatSettings`.
public struct ProjectAgentPreferencePresentation: Equatable, Sendable {
    public let options: [ProjectAgentPreferenceOption]
    public let selectedAgentID: AgentID
    public let availabilityNote: String?
    public let showsHermesChatSettings: Bool

    public init(
        options: [ProjectAgentPreferenceOption],
        selectedAgentID: AgentID,
        availabilityNote: String?,
        showsHermesChatSettings: Bool
    ) {
        self.options = options
        self.selectedAgentID = selectedAgentID
        self.availabilityNote = availabilityNote
        self.showsHermesChatSettings = showsHermesChatSettings
    }
}

/// Pure builder for project default-agent options from installation probes.
///
/// Shared by New Project and per-project Chat Settings so availability notes
/// and Claude gating stay identical. No SwiftUI / CLUI.
public enum ProjectAgentPreferencePresenter {
    public static func make(
        preferredAgentID: AgentID,
        probes: [ProjectAgentBackendProbe],
        isRemoteContext: Bool
    ) -> ProjectAgentPreferencePresentation {
        var options: [ProjectAgentPreferenceOption] = [
            ProjectAgentPreferenceOption(
                id: .hermes,
                displayName: "Hermes",
                detail: hermesDetail(from: probes)
            )
        ]
        var availabilityNote: String?

        if let claude = probes.first(where: { $0.id == .claudeCode }) {
            switch claude.status {
            case .available:
                options.append(
                    ProjectAgentPreferenceOption(
                        id: .claudeCode,
                        displayName: "Claude Code",
                        detail: diagnosticDetail(
                            version: availableVersion(claude.status),
                            path: claude.executablePath,
                            fallback: "Claude Code detected on this Mac"
                        )
                    )
                )
            case .notInstalled:
                availabilityNote =
                    "Claude Code is not installed or could not be found in the app's executable search paths."
            case .unavailable(let reason):
                availabilityNote = "Claude Code is unavailable: \(reason)"
            }
        } else if isRemoteContext {
            availabilityNote =
                "Claude Code project chat is local-only in this phase; remote windows continue to use Hermes."
        }

        let selected: AgentID
        if options.contains(where: { $0.id == preferredAgentID }) {
            selected = preferredAgentID
        } else {
            selected = .hermes
        }

        return ProjectAgentPreferencePresentation(
            options: options,
            selectedAgentID: selected,
            availabilityNote: availabilityNote,
            showsHermesChatSettings: selected == .hermes
        )
    }

    private static func hermesDetail(from probes: [ProjectAgentBackendProbe]) -> String {
        guard let hermes = probes.first(where: { $0.id == .hermes }),
              case .available = hermes.status
        else {
            return "Scarf's existing full-featured agent runtime"
        }
        return diagnosticDetail(
            version: availableVersion(hermes.status),
            path: hermes.executablePath,
            fallback: "Scarf's existing full-featured agent runtime"
        )
    }

    private static func availableVersion(_ status: AgentInstallationStatus) -> String? {
        if case .available(let version) = status {
            return version
        }
        return nil
    }

    private static func diagnosticDetail(
        version: String?,
        path: String?,
        fallback: String
    ) -> String {
        var parts: [String] = []
        if let version, !version.isEmpty {
            parts.append(version)
        }
        if let path, !path.isEmpty {
            parts.append(path)
        }
        if parts.isEmpty {
            return fallback
        }
        return parts.joined(separator: " · ")
    }
}
