import Foundation
import Testing
@testable import scarf

@Suite("Multi-agent domain")
struct AgentDomainTests {

    @Test("built-in backend identifiers are stable")
    func builtInBackendIdentifiersAreStable() {
        #expect(AgentID.hermes.rawValue == "hermes")
        #expect(AgentID.claudeCode.rawValue == "claude-code")
        #expect(AgentID("future-agent").rawValue == "future-agent")
    }

    @Test("capabilities support membership and composition")
    func capabilityMembership() {
        let capabilities: AgentCapabilities = [.streaming, .toolCalls, .sessions, .memory]

        #expect(capabilities.contains(.streaming))
        #expect(capabilities.contains(.toolCalls))
        #expect(capabilities.contains(.memory))
        #expect(!capabilities.contains(.cron))
        #expect(!capabilities.contains(.gateway))
    }

    @Test("agent identifiers and capabilities round trip through Codable")
    func codableRoundTrip() throws {
        struct Snapshot: Codable, Equatable {
            var id: AgentID
            var capabilities: AgentCapabilities
        }

        let original = Snapshot(
            id: .claudeCode,
            capabilities: [.streaming, .permissions, .sessions, .resume, .mcp]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: encoded)

        #expect(decoded == original)
    }

    @Test("generic events retain backend-neutral payloads")
    func genericEventPayloads() {
        let session = AgentSession(
            id: "session-1",
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let tool = AgentToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .running
        )
        let usage = AgentUsage(inputTokens: 10, outputTokens: 20, reasoningTokens: 5, cachedReadTokens: 2)

        #expect(AgentEvent.sessionStarted(session) == .sessionStarted(session))
        #expect(AgentEvent.toolStarted(tool) == .toolStarted(tool))
        #expect(AgentEvent.usageUpdated(usage) == .usageUpdated(usage))
        #expect(AgentEvent.textDelta("hello") == .textDelta("hello"))
    }

    @Test("unknown backend identifiers remain representable")
    func futureBackendIdentifier() throws {
        let id = AgentID("vendor.experimental-agent")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(AgentID.self, from: data)

        #expect(decoded == id)
    }
}
