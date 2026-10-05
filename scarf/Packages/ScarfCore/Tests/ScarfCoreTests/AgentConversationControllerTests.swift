import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation controller")
struct AgentConversationControllerTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>

        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var sentMessages: [AgentMessage] = []
        private var cancelledSessions: [String] = []
        private var closedSessions: [String] = []
        private var nextSessionNumber = 0

        init(id: AgentID = .claudeCode, displayName: String = "Claude Code") {
            self.id = id
            self.displayName = displayName
            var continuation: AsyncStream<AgentEvent>.Continuation!
            self.events = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus { .available(version: nil) }
        nonisolated func models() async throws -> [AgentModel] { [] }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            nextSessionNumber += 1
            return AgentSession(
                id: "session-\(nextSessionNumber)",
                backendID: id,
                workingDirectory: configuration.workingDirectory
            )
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession { session }

        func send(_ message: AgentMessage, in session: AgentSession) async throws {
            sentMessages.append(message)
        }

        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}

        func cancel(session: AgentSession) async {
            cancelledSessions.append(session.id)
        }

        func close(session: AgentSession) async {
            closedSessions.append(session.id)
        }

        func emit(_ event: AgentEvent) {
            continuation.yield(event)
        }

        func sent() -> [AgentMessage] { sentMessages }
        func cancelled() -> [String] { cancelledSessions }
        func closed() -> [String] { closedSessions }
    }

    @Test("start creates selected backend session and seeds state")
    func startSession() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let cwd = URL(fileURLWithPath: "/tmp/project")

        let session = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(workingDirectory: cwd)
        )
        let state = await controller.stateSnapshot()

        #expect(session.backendID == .claudeCode)
        #expect(session.workingDirectory == cwd)
        #expect(state.session == session)
        #expect(!state.isClosed)
    }

    @Test("send appends user turn and routes through active backend")
    func sendMessage() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        _ = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )

        try await controller.send("Hello")

        let sent = await backend.sent()
        let state = await controller.stateSnapshot()
        #expect(sent.count == 1)
        #expect(sent[0].role == .user)
        #expect(sent[0].content == "Hello")
        #expect(state.messages.last?.role == .user)
        #expect(state.messages.last?.content == "Hello")
        #expect(state.isRunning)
    }

    @Test("coordinator events reduce into observable conversation state")
    func reducesEvents() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        _ = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )

        let completedState = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.stopReason == "end_turn" {
                    return state
                }
            }
            return nil
        }

        await backend.emit(.textStarted)
        await backend.emit(.textDelta("Hello from Claude"))
        await backend.emit(.textCompleted)
        await backend.emit(.turnCompleted(stopReason: "end_turn"))

        let state = try #require(await completedState.value)
        #expect(state.messages.last?.role == .assistant)
        #expect(state.messages.last?.content == "Hello from Claude")
        #expect(state.stopReason == "end_turn")
        #expect(!state.isRunning)
    }

    @Test("cancel and close route through the active session")
    func cancelAndClose() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        _ = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )

        try await controller.cancel()
        try await controller.close()

        #expect(await backend.cancelled() == ["session-1"])
        #expect(await backend.closed() == ["session-1"])
        #expect((await controller.stateSnapshot()).isClosed)
    }

    @Test("starting a replacement session closes the previous session")
    func replacementSessionClosesPrevious() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let first = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        let second = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )

        #expect(first.id == "session-1")
        #expect(second.id == "session-2")
        #expect(await backend.closed() == ["session-1"])
        #expect((await controller.stateSnapshot()).session == second)
    }
}
