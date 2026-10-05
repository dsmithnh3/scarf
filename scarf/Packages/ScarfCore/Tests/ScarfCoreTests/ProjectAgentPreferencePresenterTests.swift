import Foundation
import Testing
@testable import ScarfCore

@Suite("Project agent preference presenter")
struct ProjectAgentPreferencePresenterTests {

    @Test("Hermes is always offered and remains the default selection")
    func hermesAlwaysDefault() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .hermes,
            probes: [],
            isRemoteContext: false
        )

        #expect(presentation.options.map(\.id) == [.hermes])
        #expect(presentation.selectedAgentID == .hermes)
        #expect(presentation.availabilityNote == nil)
        #expect(presentation.showsHermesChatSettings)
        #expect(
            presentation.options[0].detail
                == "Scarf's existing full-featured agent runtime"
        )
    }

    @Test("Claude is offered only when the probe reports available")
    func claudeOfferedWhenAvailable() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .hermes,
            probes: [
                ProjectAgentBackendProbe(
                    id: .claudeCode,
                    displayName: "Claude Code",
                    executablePath: "/opt/homebrew/bin/claude",
                    status: .available(version: "2.1.0")
                )
            ],
            isRemoteContext: false
        )

        #expect(presentation.options.map(\.id) == [.hermes, .claudeCode])
        #expect(presentation.selectedAgentID == .hermes)
        #expect(presentation.availabilityNote == nil)
        #expect(
            presentation.options.first(where: { $0.id == .claudeCode })?.detail
                == "2.1.0 · /opt/homebrew/bin/claude"
        )
    }

    @Test("Hermes option detail includes version and path when probe is available")
    func hermesDetailIncludesDiagnostics() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .hermes,
            probes: [
                ProjectAgentBackendProbe(
                    id: .hermes,
                    displayName: "Hermes",
                    executablePath: "/opt/homebrew/bin/hermes",
                    status: .available(version: "3.5.0")
                )
            ],
            isRemoteContext: false
        )

        #expect(
            presentation.options[0].detail
                == "3.5.0 · /opt/homebrew/bin/hermes"
        )
    }

    @Test("Claude notInstalled yields note and no Claude option")
    func claudeNotInstalledNote() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .hermes,
            probes: [
                ProjectAgentBackendProbe(
                    id: .claudeCode,
                    displayName: "Claude Code",
                    executablePath: nil,
                    status: .notInstalled
                )
            ],
            isRemoteContext: false
        )

        #expect(presentation.options.map(\.id) == [.hermes])
        #expect(
            presentation.availabilityNote
                == "Claude Code is not installed or could not be found in the app's executable search paths."
        )
    }

    @Test("Remote context without Claude probe explains local-only limitation")
    func remoteWithoutClaude() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .hermes,
            probes: [],
            isRemoteContext: true
        )

        #expect(presentation.options.map(\.id) == [.hermes])
        #expect(
            presentation.availabilityNote
                == "Claude Code project chat is local-only in this phase; remote windows continue to use Hermes."
        )
    }

    @Test("Stored Claude preference falls back to Hermes when Claude is unavailable")
    func invalidClaudePreferenceFallsBack() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .claudeCode,
            probes: [
                ProjectAgentBackendProbe(
                    id: .claudeCode,
                    displayName: "Claude Code",
                    executablePath: nil,
                    status: .notInstalled
                )
            ],
            isRemoteContext: false
        )

        #expect(presentation.selectedAgentID == .hermes)
        #expect(presentation.showsHermesChatSettings)
        #expect(presentation.availabilityNote != nil)
    }

    @Test("Stored Claude preference is kept when Claude is available")
    func keepsClaudePreferenceWhenAvailable() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .claudeCode,
            probes: [
                ProjectAgentBackendProbe(
                    id: .claudeCode,
                    displayName: "Claude Code",
                    executablePath: "/usr/local/bin/claude",
                    status: .available(version: nil)
                )
            ],
            isRemoteContext: false
        )

        #expect(presentation.selectedAgentID == .claudeCode)
        #expect(!presentation.showsHermesChatSettings)
        #expect(
            presentation.options.first(where: { $0.id == .claudeCode })?.detail
                == "/usr/local/bin/claude"
        )
    }

    @Test("Claude unavailable reason is surfaced when probe reports unavailable")
    func claudeUnavailableReason() {
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: .hermes,
            probes: [
                ProjectAgentBackendProbe(
                    id: .claudeCode,
                    displayName: "Claude Code",
                    executablePath: "/opt/homebrew/bin/claude",
                    status: .unavailable(reason: "permission denied")
                )
            ],
            isRemoteContext: false
        )

        #expect(presentation.options.map(\.id) == [.hermes])
        #expect(
            presentation.availabilityNote
                == "Claude Code is unavailable: permission denied"
        )
    }
}
