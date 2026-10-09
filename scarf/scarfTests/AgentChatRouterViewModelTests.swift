import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Agent chat router opt-in")
@MainActor
struct AgentChatRouterViewModelTests {
    @Test("Hermes preferred project stays legacy when opt-in is off")
    func hermesFlagOffRoutesLegacy() async throws {
        let fixture = try ProjectRouteFixture(preferred: .hermes)
        defer { fixture.cleanup() }

        let router = AgentChatRouterViewModel(
            context: fixture.home.context,
            isHermesAgentChatEnabled: { false }
        )
        await router.resolve(projectPath: fixture.projectPath)

        guard case .legacy(let path) = router.route else {
            Issue.record("expected legacy route, got \(router.route)")
            return
        }
        #expect(path == fixture.projectPath)
    }

    @Test("Hermes preferred project routes to AgentChat when opt-in is on")
    func hermesFlagOnRoutesAgent() async throws {
        let fixture = try ProjectRouteFixture(preferred: .hermes)
        defer { fixture.cleanup() }

        let router = AgentChatRouterViewModel(
            context: fixture.home.context,
            isHermesAgentChatEnabled: { true }
        )
        await router.resolve(projectPath: fixture.projectPath)

        guard case .agent(let project, _) = router.route else {
            Issue.record("expected agent route, got \(router.route)")
            return
        }
        #expect(project.rootPath == fixture.projectPath)
        #expect(project.preferredAgentID == .hermes)
    }

    @Test("Claude preferred project routes to AgentChat regardless of Hermes opt-in")
    func claudeRoutesAgentWithFlagOff() async throws {
        let fixture = try ProjectRouteFixture(preferred: .claudeCode)
        defer { fixture.cleanup() }

        let router = AgentChatRouterViewModel(
            context: fixture.home.context,
            isHermesAgentChatEnabled: { false }
        )
        await router.resolve(projectPath: fixture.projectPath)

        guard case .agent(let project, _) = router.route else {
            Issue.record("expected agent route, got \(router.route)")
            return
        }
        #expect(project.preferredAgentID == .claudeCode)
    }

    @Test("absent project record stays legacy Hermes compatibility default")
    func absentRecordRoutesLegacy() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let missing = home.url.appendingPathComponent("no-such-project", isDirectory: true).path

        let router = AgentChatRouterViewModel(
            context: home.context,
            isHermesAgentChatEnabled: { true }
        )
        await router.resolve(projectPath: missing)

        guard case .legacy(let path) = router.route else {
            Issue.record("expected legacy route, got \(router.route)")
            return
        }
        #expect(path == missing)
    }

    @Test("opt-in key defaults false when unset")
    func optInKeyDefaultsFalse() {
        let suiteName = "scarf.router.optin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(defaults.bool(forKey: HermesAgentChatOptIn.userDefaultsKey) == false)
        #expect(HermesAgentChatOptIn.userDefaultsKey == "scarf.experimental.hermesAgentChat")
    }
}

@MainActor
private struct ProjectRouteFixture {
    let home: TempHermesHome
    let projectPath: String

    init(preferred: AgentID) throws {
        home = try TempHermesHome()
        let projectURL = home.url.appendingPathComponent("projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".scarf", isDirectory: true),
            withIntermediateDirectories: true
        )
        projectPath = projectURL.path

        let store = ProjectStore(context: home.context)
        var seed = ScarfProject(name: "Demo", rootPath: projectPath)
        seed.preferredAgentID = preferred
        try store.save(seed)
    }

    func cleanup() {
        home.cleanup()
    }
}
