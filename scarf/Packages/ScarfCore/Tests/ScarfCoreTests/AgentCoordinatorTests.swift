import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent coordinator")
struct AgentCoordinatorTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions, .permissions]
        nonisolated let events: AsyncStream<AgentEvent>

        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var sentMessages: [AgentMessage] = []

        init(id: AgentID, displayName: String) {
            self.id = id
            self.displayName = displayName
            var continuation: AsyncStream<AgentEvent>.Continuation!
            self.events = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus { .available(version: nil) }
        nonisolated func models() async throws -> [AgentModel] { [] }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            AgentSession(id: "\(id.rawValue)-new", backendID: id, workingDirectory: configuration.workingDirectory)
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession {
            AgentSession(id: session.id + "-resumed", backendID: id, workingDirectory: session.workingDirectory)
        }

        func send(_ message: AgentMessage, in session: AgentSession) async throws {
            sentMessages.append(message)
        }

        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func emit(_ event: AgentEvent) {
            continuation.yield(event)
        }

        func sentCount() -> Int { sentMessages.count }
    }

    @Test("default session creation routes to Hermes")
    func defaultRoutesToHermes() async throws {
        let coordinator = AgentCoordinator()
        let hermes = RecordingBackend(id: .hermes, displayName: "Hermes")
        await coordinator.register(hermes)

        let session = try await coordinator.createSession(configuration: AgentSessionConfiguration())
        #expect(session.backendID == .hermes)
        #expect(session.id == "hermes-new")
    }

    @Test("explicit backend selection routes independently")
    func explicitBackend() async throws {
        let coordinator = AgentCoordinator()
        await coordinator.register(RecordingBackend(id: .hermes, displayName: "Hermes"))
        await coordinator.register(RecordingBackend(id: .claudeCode, displayName: "Claude Code"))

        let session = try await coordinator.createSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        #expect(session.backendID == .claudeCode)
    }

    @Test("resume returns backend effective session identity")
    func resumeReturnsEffectiveSession() async throws {
        let coordinator = AgentCoordinator()
        await coordinator.register(RecordingBackend(id: .hermes, displayName: "Hermes"))
        let original = AgentSession(id: "old", backendID: .hermes)

        let resumed = try await coordinator.resumeSession(original)
        #expect(resumed.id == "old-resumed")
    }

    @Test("send routes by session backend")
    func sendRoutesBySessionBackend() async throws {
        let coordinator = AgentCoordinator()
        let claude = RecordingBackend(id: .claudeCode, displayName: "Claude Code")
        await coordinator.register(claude)
        let session = AgentSession(id: "c", backendID: .claudeCode)

        try await coordinator.send(AgentMessage(role: .user, content: "hello"), in: session)
        #expect(await claude.sentCount() == 1)
    }

    @Test("registered backend events are forwarded")
    func forwardsEvents() async throws {
        let coordinator = AgentCoordinator()
        let hermes = RecordingBackend(id: .hermes, displayName: "Hermes")
        await coordinator.register(hermes)

        let task = Task { () -> AgentEvent? in
            var iterator = coordinator.events.makeAsyncIterator()
            return await iterator.next()
        }
        await hermes.emit(.textDelta("forwarded"))
        let received = await task.value
        #expect(received == .textDelta("forwarded"))
    }

    @Test("missing backend fails explicitly")
    func missingBackend() async {
        let coordinator = AgentCoordinator()
        do {
            _ = try await coordinator.createSession(
                backendID: .claudeCode,
                configuration: AgentSessionConfiguration()
            )
            Issue.record("Expected backendUnavailable")
        } catch let error as AgentCoordinatorError {
            #expect(error == .backendUnavailable(.claudeCode))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
