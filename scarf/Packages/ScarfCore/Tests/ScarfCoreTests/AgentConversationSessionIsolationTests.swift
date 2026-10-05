import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation session isolation")
struct AgentConversationSessionIsolationTests {
    private actor ScopedBackend: SessionScopedAgentBackend {
        nonisolated let id: AgentID = .claudeCode
        nonisolated let displayName = "Scoped Claude"
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>
        nonisolated let sessionEvents: AsyncStream<AgentBackendEvent>

        private let eventContinuation: AsyncStream<AgentEvent>.Continuation
        private let sessionEventContinuation: AsyncStream<AgentBackendEvent>.Continuation

        init() {
            var eventContinuation: AsyncStream<AgentEvent>.Continuation!
            events = AsyncStream { eventContinuation = $0 }
            self.eventContinuation = eventContinuation

            var sessionEventContinuation: AsyncStream<AgentBackendEvent>.Continuation!
            sessionEvents = AsyncStream { sessionEventContinuation = $0 }
            self.sessionEventContinuation = sessionEventContinuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus { .available(version: nil) }
        nonisolated func models() async throws -> [AgentModel] { [] }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            let sessionID = configuration.metadata["testSessionID"] ?? UUID().uuidString
            return AgentSession(id: sessionID, backendID: id, workingDirectory: configuration.workingDirectory)
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession { session }
        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func emit(_ event: AgentEvent, sessionID: String) {
            // Compatibility stream intentionally receives the same event. The
            // coordinator must prefer the session-scoped stream for this backend.
            eventContinuation.yield(event)
            sessionEventContinuation.yield(AgentBackendEvent(sessionID: sessionID, event: event))
        }
    }

    @Test("two conversations on one backend never consume each other's events")
    func twoSessionIsolation() async throws {
        let coordinator = AgentCoordinator()
        let backend = ScopedBackend()
        await coordinator.register(backend)

        let first = AgentConversationController(coordinator: coordinator)
        let second = AgentConversationController(coordinator: coordinator)

        _ = try await first.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(metadata: ["testSessionID": "session-a"])
        )
        _ = try await second.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(metadata: ["testSessionID": "session-b"])
        )

        await backend.emit(.textStarted, sessionID: "session-a")
        await backend.emit(.textDelta("alpha"), sessionID: "session-a")
        await backend.emit(.textCompleted, sessionID: "session-a")
        await backend.emit(.turnCompleted(stopReason: "a-done"), sessionID: "session-a")

        await backend.emit(.textStarted, sessionID: "session-b")
        await backend.emit(.textDelta("beta"), sessionID: "session-b")
        await backend.emit(.textCompleted, sessionID: "session-b")
        await backend.emit(.turnCompleted(stopReason: "b-done"), sessionID: "session-b")

        // Allow both independent coordinator subscriptions to consume the
        // already-enqueued events before reading their actor-isolated states.
        try await Task.sleep(for: .milliseconds(100))

        let firstState = await first.stateSnapshot()
        let secondState = await second.stateSnapshot()

        #expect(firstState.messages.map(\.content) == ["alpha"])
        #expect(firstState.stopReason == "a-done")
        #expect(secondState.messages.map(\.content) == ["beta"])
        #expect(secondState.stopReason == "b-done")
    }
}
