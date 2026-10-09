import Foundation
import Testing
import ScarfCore
@testable import scarf

/// Remote/SSH Hermes AgentChat smoke (automated slice).
///
/// Full create/send/permission over live SSH remains a manual checklist item
/// (see `docs/MULTI_AGENT_ROADMAP.md` production B smoke matrix). This suite
/// proves the remote window still registers Hermes, can mint a conversation
/// controller for a Hermes-preferred project, and does **not** register Claude.
@Suite("Remote Hermes AgentChat opt-in smoke")
@MainActor
struct AgentRuntimeRemoteHermesOptInTests {
    @Test("remote AgentRuntime registers Hermes and builds a conversation controller")
    func remoteHermesControllerAvailable() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }

        let projectURL = home.url.appendingPathComponent("projects/remote-demo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".scarf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let localStore = ProjectStore(context: home.context)
        var project = ScarfProject(name: "Remote Demo", rootPath: projectURL.path)
        project.preferredAgentID = .hermes
        try localStore.save(project)

        let remote = ServerContext(
            id: UUID(),
            displayName: "ssh-smoke-box",
            kind: .ssh(SSHConfig(
                host: "ssh-smoke-box",
                remoteHome: home.url.path,
                hermesBinaryHint: "/usr/local/bin/hermes"
            ))
        )
        // ProjectStore on SSH uses transport; for this smoke we only need the
        // in-memory ScarfProject + AgentRuntime registration path.
        let runtime = AgentRuntime(context: remote)
        await runtime.configureIfNeeded()

        let hermesBackend = await runtime.backend(for: project)
        #expect(hermesBackend?.id == .hermes)

        var claudeProject = project
        claudeProject.preferredAgentID = .claudeCode
        let claudeBackend = await runtime.backend(for: claudeProject)
        #expect(claudeBackend == nil)

        let controller = await runtime.conversationController(for: project)
        #expect(controller != nil)
    }

    @Test("opt-in key is the documented experimental flag with default-on semantics")
    func optInKeyMatchesPlan() {
        #expect(HermesAgentChatOptIn.userDefaultsKey == "scarf.experimental.hermesAgentChat")
        let suiteName = "scarf.remote.optin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(HermesAgentChatOptIn.isEnabled(in: defaults) == true)
    }
}
