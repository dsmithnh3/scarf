import Testing
import ScarfCore
@testable import scarf

@Suite("Hermes agent backend")
struct HermesBackendTests {
    @Test("Hermes advertises its existing first-class capabilities")
    func capabilities() {
        let backend = HermesBackend(context: .local, installationProbe: { .available(version: "test") })
        let capabilities = backend.capabilities

        #expect(backend.id == .hermes)
        #expect(backend.displayName == "Hermes")
        #expect(capabilities.contains(.streaming))
        #expect(capabilities.contains(.toolCalls))
        #expect(capabilities.contains(.permissions))
        #expect(capabilities.contains(.sessions))
        #expect(capabilities.contains(.resume))
        #expect(capabilities.contains(.mcp))
        #expect(capabilities.contains(.skills))
        #expect(capabilities.contains(.memory))
        #expect(capabilities.contains(.cron))
        #expect(capabilities.contains(.gateway))
        #expect(capabilities.contains(.proxy))
        #expect(capabilities.contains(.remoteExecution))
    }

    @Test("installation status delegates to injected probe")
    func installationProbe() async {
        let backend = HermesBackend(context: .local, installationProbe: { .available(version: "3.5-test") })
        #expect(await backend.installationStatus() == .available(version: "3.5-test"))
    }

    @Test("fetchConversationHistory returns loader results for Hermes sessions")
    func fetchConversationHistory() async throws {
        let expected = [
            AgentMessage(role: .user, content: "from state.db"),
            AgentMessage(role: .assistant, content: "mapped"),
        ]
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") },
            conversationHistoryLoader: { _, sessionID in
                #expect(sessionID == "sess-hermes-1")
                return expected
            }
        )
        let session = AgentSession(id: "sess-hermes-1", backendID: .hermes)
        let history = try await backend.fetchConversationHistory(for: session)
        #expect(history == expected)
    }
}
