import Foundation
import Testing
@testable import ScarfCore

@Suite("Project agent preference persistence")
struct ProjectAgentPreferenceStoreTests {
    @Test("Claude preference persists and Hermes restores compatibility default")
    func preferenceRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-pref-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let projectURL = home.appendingPathComponent("projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".scarf", isDirectory: true),
            withIntermediateDirectories: true
        )

        let context = ServerContext.local(home: home)
        let store = ProjectStore(context: context)
        var seed = ScarfProject(name: "Demo", rootPath: projectURL.path)
        seed.extra["futureMetadata"] = .string("preserve-me")
        try store.save(seed)

        try store.setPreferredAgentID(.claudeCode, projectPath: projectURL.path, name: "Demo")
        let claude = try #require(store.load(projectPath: projectURL.path))
        #expect(claude.preferredAgentID == .claudeCode)
        #expect(claude.extra["preferredAgentId"] == .string("claude-code"))
        #expect(claude.extra["futureMetadata"] == .string("preserve-me"))

        try store.setPreferredAgentID(.hermes, projectPath: projectURL.path, name: "Demo")
        let hermes = try #require(store.load(projectPath: projectURL.path))
        #expect(hermes.preferredAgentID == .hermes)
        #expect(hermes.extra["preferredAgentId"] == nil)
        #expect(hermes.extra["futureMetadata"] == .string("preserve-me"))
    }

    @Test("missing project record derives before storing preference")
    func derivesMissingRecord() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-pref-derive-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let projectURL = home.appendingPathComponent("projects/bare", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let context = ServerContext.local(home: home)
        let store = ProjectStore(context: context)
        try store.setPreferredAgentID(.claudeCode, projectPath: projectURL.path, name: "Bare")

        let loaded = try #require(store.load(projectPath: projectURL.path))
        #expect(loaded.name == "Bare")
        #expect(loaded.rootPath == projectURL.path)
        #expect(loaded.preferredAgentID == .claudeCode)
    }
}
