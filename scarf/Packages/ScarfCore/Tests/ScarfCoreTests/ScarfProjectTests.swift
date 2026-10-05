import Testing
import Foundation
@testable import ScarfCore

/// Codable round-trip + lenient/additive-decode coverage for the
/// first-class `ScarfProject` record. Pure data — no disk.
@Suite struct ScarfProjectTests {

    @Test func roundTripPreservesAllFields() throws {
        let project = ScarfProject(
            id: UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!,
            name: "Site Status",
            rootPath: "/Users/x/Projects/site-status",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            modelPresetId: "12345678-1234-1234-1234-123456789abc",
            board: "scarf:site-status",
            cronJobIds: ["job-1", "job-2"],
            memoryNamespace: "scarf-template:author/site",
            secretsScope: ["api_token", "webhook_secret"],
            templateLockRef: "/Users/x/Projects/site-status/.scarf/template.lock.json",
            hostBindings: [
                .init(serverId: "00000000-0000-0000-0000-000000000001",
                      rootPath: "/Users/x/Projects/site-status",
                      materializedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ]
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ScarfProject.self, from: data)

        #expect(decoded.id == project.id)
        #expect(decoded.name == project.name)
        #expect(decoded.rootPath == project.rootPath)
        #expect(decoded.schemaVersion == ScarfProject.currentSchemaVersion)
        #expect(decoded.modelPresetId == project.modelPresetId)
        #expect(decoded.board == project.board)
        #expect(decoded.cronJobIds == project.cronJobIds)
        #expect(decoded.memoryNamespace == project.memoryNamespace)
        #expect(decoded.secretsScope == project.secretsScope)
        #expect(decoded.templateLockRef == project.templateLockRef)
        #expect(decoded.hostBindings.count == 1)
        #expect(decoded.hostBindings.first?.serverId == "00000000-0000-0000-0000-000000000001")
        #expect(decoded.preferredAgentID == .hermes)
        // ISO-8601 dates round-trip to the second.
        #expect(abs(decoded.createdAt.timeIntervalSince(project.createdAt)) < 1)
        #expect(abs(decoded.updatedAt.timeIntervalSince(project.updatedAt)) < 1)
    }

    /// The deferred-for-M1 scoping fields default to empty and survive
    /// a round-trip as empty.
    @Test func scopingFieldsDefaultEmpty() throws {
        let project = ScarfProject(name: "Bare", rootPath: "/tmp/bare")
        #expect(project.scopedToolsets.isEmpty)
        #expect(project.scopedSkills.isEmpty)
        #expect(project.preferredAgentID == .hermes)
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ScarfProject.self, from: data)
        #expect(decoded.scopedToolsets.isEmpty)
        #expect(decoded.scopedSkills.isEmpty)
        #expect(decoded.hostBindings.isEmpty)
        #expect(decoded.board == nil)
        #expect(decoded.templateLockRef == nil)
        #expect(decoded.preferredAgentID == .hermes)
    }

    /// A minimal record carrying only the three required keys must decode
    /// — collections fill empty, optionals nil, schemaVersion current,
    /// dates default to "now". This is the additive-forward-compat
    /// guarantee for `.scarf/project.json`.
    @Test func minimalRecordDecodes() throws {
        let json = """
        {
          "id": "AAAAAAAA-1111-2222-3333-444444444444",
          "name": "Minimal",
          "rootPath": "/tmp/minimal"
        }
        """
        let decoded = try JSONDecoder().decode(ScarfProject.self, from: Data(json.utf8))
        #expect(decoded.name == "Minimal")
        #expect(decoded.rootPath == "/tmp/minimal")
        #expect(decoded.schemaVersion == ScarfProject.currentSchemaVersion)
        #expect(decoded.cronJobIds.isEmpty)
        #expect(decoded.secretsScope.isEmpty)
        #expect(decoded.modelPresetId == nil)
        #expect(decoded.hostBindings.isEmpty)
        #expect(decoded.preferredAgentID == .hermes)
    }

    @Test func preferredClaudeAgentRoundTripsThroughExtraStorage() throws {
        var project = ScarfProject(name: "Claude Project", rootPath: "/tmp/claude")
        project.preferredAgentID = .claudeCode

        #expect(project.extra["preferredAgentId"] == .string("claude-code"))

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ScarfProject.self, from: data)
        #expect(decoded.preferredAgentID == .claudeCode)
        #expect(decoded.extra["preferredAgentId"] == .string("claude-code"))
    }

    @Test func resettingPreferredAgentToHermesRemovesCompatibilityKey() {
        var project = ScarfProject(name: "Reset", rootPath: "/tmp/reset")
        project.preferredAgentID = .claudeCode
        project.preferredAgentID = .hermes

        #expect(project.preferredAgentID == .hermes)
        #expect(project.extra["preferredAgentId"] == nil)
    }

    /// Unknown future keys are ignored by the typed model but preserved in
    /// `extra`, allowing newer and older Scarf builds to share a project.
    @Test func unknownKeysAreIgnored() throws {
        let json = """
        {
          "id": "AAAAAAAA-1111-2222-3333-444444444444",
          "name": "Future",
          "rootPath": "/tmp/future",
          "someFieldFromTomorrow": { "nested": true }
        }
        """
        let decoded = try JSONDecoder().decode(ScarfProject.self, from: Data(json.utf8))
        #expect(decoded.name == "Future")
        #expect(decoded.extra["someFieldFromTomorrow"] == .object(["nested": .bool(true)]))
    }
}
