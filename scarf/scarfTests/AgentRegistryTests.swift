import Foundation
import Testing
@testable import scarf

@Suite("Agent backend registry")
struct AgentRegistryTests {

    private struct StubBackend: AgentBackend {
        let id: AgentID
        let displayName: String
        let capabilities: AgentCapabilities
        let events: AsyncStream<AgentEvent>

        init(id: AgentID, displayName: String, capabilities: AgentCapabilities = []) {
            self.id = id
            self.displayName = displayName
            self.capabilities = capabilities
            self.events = AsyncStream { continuation in
                continuation.finish()
            }
        }

        func installationStatus() async -> AgentInstallationStatus { .available(version: nil) }
        func models() async throws -> [AgentModel] { [] }
        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            AgentSession(id: "stub", backendID: id, workingDirectory: configuration.workingDirectory)
        }
        func resumeSession(_ session: AgentSession) async throws {}
        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}
    }

    @Test("registry resolves registered backend")
    func resolvesBackend() async {
        let registry = AgentRegistry()
        let hermes = StubBackend(id: .hermes, displayName: "Hermes", capabilities: [.streaming])

        await registry.register(hermes)
        let resolved = await registry.backend(for: .hermes)

        #expect(resolved?.id == .hermes)
        #expect(resolved?.displayName == "Hermes")
    }

    @Test("registry replacement is deterministic for same backend id")
    func replacesBackendWithSameID() async {
        let registry = AgentRegistry()
        await registry.register(StubBackend(id: .hermes, displayName: "Old Hermes"))
        await registry.register(StubBackend(id: .hermes, displayName: "New Hermes"))

        let resolved = await registry.backend(for: .hermes)
        #expect(resolved?.displayName == "New Hermes")
        #expect(await registry.count == 1)
    }

    @Test("registry lists backends in stable id order")
    func stableListing() async {
        let registry = AgentRegistry()
        await registry.register(StubBackend(id: .claudeCode, displayName: "Claude Code"))
        await registry.register(StubBackend(id: .hermes, displayName: "Hermes"))

        let ids = await registry.availableBackends().map(\.id)
        #expect(ids == [.claudeCode, .hermes])
    }

    @Test("missing backend returns nil")
    func missingBackend() async {
        let registry = AgentRegistry()
        #expect(await registry.backend(for: AgentID("missing")) == nil)
    }
}
