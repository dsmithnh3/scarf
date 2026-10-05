import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent slash hint presenter")
struct AgentSlashHintPresenterTests {

    private let hermesCaps = AgentSlashHintPresenter.defaultCapabilities(for: .hermes)
    private let claudeCaps = AgentSlashHintPresenter.defaultCapabilities(for: .claudeCode)

    @Test("menu shows only for a bare slash token without whitespace")
    func menuVisibilityMatchesHermesComposerRules() {
        #expect(AgentSlashHintPresenter.shouldShowMenu(draft: "/"))
        #expect(AgentSlashHintPresenter.shouldShowMenu(draft: "/hel"))
        #expect(!AgentSlashHintPresenter.shouldShowMenu(draft: "/help "))
        #expect(!AgentSlashHintPresenter.shouldShowMenu(draft: "/help\n"))
        #expect(!AgentSlashHintPresenter.shouldShowMenu(draft: "hello"))
        #expect(!AgentSlashHintPresenter.shouldShowMenu(draft: ""))
        #expect(AgentSlashHintPresenter.menuQuery(draft: "/hel") == "hel")
        #expect(AgentSlashHintPresenter.menuQuery(draft: "/") == "")
    }

    @Test("Hermes presentation surfaces Scarf-local and Hermes ACP hints")
    func hermesPresentationSurfacesCatalogHints() {
        let presenter = AgentSlashHintPresenter(
            backendID: .hermes,
            capabilities: hermesCaps
        )

        let bare = presenter.presentation(for: "/")
        #expect(bare.isVisible)
        #expect(!bare.catalogIsEmpty)
        #expect(bare.hints.map(\.name).contains("scarf-help"))
        #expect(bare.hints.map(\.name).contains("compress"))
        #expect(bare.hints.map(\.name).contains("steer"))
        #expect(!bare.hints.map(\.name).contains("clear"))
        #expect(!bare.hints.map(\.name).contains("permissions"))

        let filtered = presenter.presentation(for: "/scarf-h")
        #expect(filtered.hints.map(\.name) == ["scarf-help"])
        #expect(filtered.query == "scarf-h")
    }

    @Test("Claude presentation keeps catalog empty of Claude commands and omits Hermes roster")
    func claudePresentationStaysTruthful() {
        let presenter = AgentSlashHintPresenter(
            backendID: .claudeCode,
            capabilities: claudeCaps
        )

        let bare = presenter.presentation(for: "/")
        #expect(bare.isVisible)
        #expect(!bare.catalogIsEmpty) // Scarf-local builtins still surface
        #expect(bare.hints.allSatisfy { $0.source == .scarfLocal })
        #expect(bare.hints.map(\.name).contains("scarf-help"))
        #expect(!bare.hints.map(\.name).contains("compress"))
        #expect(!bare.hints.map(\.name).contains("steer"))
        #expect(!bare.hints.map(\.name).contains("permissions"))
        #expect(!claudeCaps.contains(.permissions))
        #expect(!claudeCaps.contains(.cron))
        #expect(!bare.hints.map(\.name).contains("scarf-cron"))
    }

    @Test("presentation hides once the user starts typing arguments")
    func presentationHidesAfterSpace() {
        let presenter = AgentSlashHintPresenter(
            backendID: .hermes,
            capabilities: hermesCaps
        )
        let afterSpace = presenter.presentation(for: "/help ")
        #expect(!afterSpace.isVisible)
        #expect(afterSpace.hints.isEmpty)
    }

    @Test("accepting a hint returns insertion text only while the menu is open")
    func acceptingHintFormatsInsertionText() {
        let presenter = AgentSlashHintPresenter(
            backendID: .hermes,
            capabilities: hermesCaps
        )
        let help = presenter.presentation(for: "/scarf-h").hints[0]
        #expect(presenter.accepting(help, draft: "/scarf-h") == "/scarf-help")
        #expect(presenter.accepting(help, draft: "plain") == nil)

        let cron = presenter.presentation(for: "/scarf-c").hints.first { $0.name == "scarf-cron" }
        #expect(cron != nil)
        #expect(presenter.accepting(cron!, draft: "/scarf-c") == "/scarf-cron ")
    }

    @Test("capability gating does not advertise unsupported commands")
    func capabilityGatingHidesUnsupportedCommands() {
        let presenter = AgentSlashHintPresenter(
            backendID: .hermes,
            capabilities: [.streaming, .sessions] // no .toolCalls / .cron
        )
        let hints = presenter.presentation(for: "/").hints
        #expect(!hints.map(\.name).contains("tools"))
        #expect(!hints.map(\.name).contains("scarf-cron"))
        #expect(hints.map(\.name).contains("help"))
        #expect(hints.map(\.name).contains("scarf-help"))
    }
}
