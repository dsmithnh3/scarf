import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation attribution fallback resume")
struct AgentConversationFallbackResumeTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID = .hermes
        nonisolated let displayName = "Hermes"
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions, .resume]
        nonisolated let events: AsyncStream<AgentEvent>
        private let continuation: AsyncStream<AgentEvent>.Continuation
        private(set) var resumedIDs: [String] = []
        private(set) var created = 0
        private var failingResumeIDs: Set<String> = []

        init() {
            var continuation: AsyncStream<AgentEvent>.Continuation!
            self.events = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus {
            .available(version: "test")
        }

        nonisolated func models() async throws -> [AgentModel] { [] }

        func failResume(for id: String) {
            failingResumeIDs.insert(id)
        }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            created += 1
            return AgentSession(
                id: "minted-\(created)",
                backendID: id,
                workingDirectory: configuration.workingDirectory
            )
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession {
            resumedIDs.append(session.id)
            if failingResumeIDs.contains(session.id) {
                throw AgentError(code: "test.resume-failed", message: "boom", isRecoverable: true)
            }
            return session
        }

        func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage] {
            [
                AgentMessage(role: .user, content: "from-\(session.id)"),
                AgentMessage(role: .assistant, content: "ok"),
            ]
        }

        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func resumeCount() -> Int { resumedIDs.count }
        func createCount() -> Int { created }
        func resumed() -> [String] { resumedIDs }
    }

    @Test("fallbackSessionIDs resume first successful Hermes id when identity empty")
    func fallbackResumesAttributedSession() async throws {
        let backend = RecordingBackend()
        await backend.failResume(for: "dead")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let session = try await controller.startOrRestorePersistedSession(
            backendID: .hermes,
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp/proj")
            ),
            fallbackSessionIDs: ["dead", "alive"]
        )

        #expect(session.id == "alive")
        #expect(await backend.resumed() == ["dead", "alive"])
        #expect(await backend.createCount() == 0)

        let state = await controller.stateSnapshot()
        #expect(state.messages.map(\.content).contains("from-alive"))
    }

    @Test("all fallbacks failing mints a fresh session")
    func allFallbacksFailCreatesFresh() async throws {
        let backend = RecordingBackend()
        await backend.failResume(for: "a")
        await backend.failResume(for: "b")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let session = try await controller.startOrRestorePersistedSession(
            backendID: .hermes,
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp/proj")
            ),
            fallbackSessionIDs: ["a", "b"]
        )

        #expect(session.id.hasPrefix("minted-"))
        #expect(await backend.createCount() == 1)
    }
}
