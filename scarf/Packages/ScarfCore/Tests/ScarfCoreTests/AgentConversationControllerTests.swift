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

    @Test("late events from a replaced session do not modify the new session")
    func replacementIgnoresLatePreviousSessionEvents() async throws {
        let coordinator = AgentCoordinator()
        let backend = ScopedRecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let first = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(metadata: ["testSessionID": "session-a"])
        )
        let second = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(metadata: ["testSessionID": "session-b"])
        )

        let completed = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.stopReason == "b-done" { return state }
            }
            return nil
        }

        await backend.emit(.textDelta("from-a"), sessionID: first.id)
        await backend.emit(.textCompleted, sessionID: first.id)
        await backend.emit(.textDelta("from-b"), sessionID: second.id)
        await backend.emit(.textCompleted, sessionID: second.id)
        await backend.emit(.turnCompleted(stopReason: "b-done"), sessionID: second.id)

        let state = try #require(await completed.value)
        #expect(state.session == second)
        #expect(state.messages.map(\.content) == ["from-b"])
        #expect(!state.isClosed)
        #expect(await backend.closed() == [first.id])
    }

    @Test("resuming a different session closes the previous session")
    func resumeReplacementClosesPrevious() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let first = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        let replacement = AgentSession(id: "session-b", backendID: .claudeCode, workingDirectory: nil)
        let resumed = try await controller.resumeSession(replacement)

        #expect(first.id == "session-1")
        #expect(resumed.id == "session-b")
        #expect(await backend.closed() == ["session-1"])
        #expect((await controller.stateSnapshot()).session == resumed)
        #expect((await controller.stateSnapshot()).isClosed == false)
    }

    @Test("resuming the active session does not close it")
    func resumeActiveSessionDoesNotClose() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let first = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        let resumed = try await controller.resumeSession(first)

        #expect(resumed.id == first.id)
        #expect(await backend.closed().isEmpty)
        #expect((await controller.stateSnapshot()).session?.id == first.id)
        #expect((await controller.stateSnapshot()).isClosed == false)
    }

    @Test("late unscoped events after close do not mutate conversation state")
    func lateUnscopedEventsAfterCloseDoNotMutateState() async throws {
        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let session = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )

        let drafted = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.assistantDraft == "kept" { return state }
            }
            return nil
        }
        await backend.emit(.textDelta("kept"))
        _ = try #require(await drafted.value)
        try await controller.close()

        let stream = await coordinator.subscribeToRoutedEvents()
        let forwarded = Task<UInt64?, Never> {
            for await routed in stream {
                if routed.event == .turnCompleted(stopReason: "probe-done") {
                    return routed.sequence
                }
            }
            return nil
        }
        await backend.emit(.textDelta("late"))
        await backend.emit(.sessionStarted(AgentSession(id: "resurrected", backendID: .claudeCode)))
        await backend.emit(.turnCompleted(stopReason: "probe-done"))
        let sequence = try #require(await forwarded.value)
        await controller.waitUntilRoutedSequenceConsumed(sequence)

        let state = await controller.stateSnapshot()
        #expect(state.isClosed)
        #expect(state.session?.id == session.id)
        #expect(state.stopReason == nil)
        #expect(state.assistantDraft.isEmpty)
        #expect(state.messages.map(\.content) == ["kept"])
    }

    @Test("late scoped events after close do not mutate conversation state")
    func lateScopedEventsAfterCloseDoNotMutateState() async throws {
        let coordinator = AgentCoordinator()
        let backend = ScopedRecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let session = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(metadata: ["testSessionID": "session-a"])
        )

        let drafted = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.assistantDraft == "kept" { return state }
            }
            return nil
        }
        await backend.emit(.textDelta("kept"), sessionID: session.id)
        _ = try #require(await drafted.value)
        try await controller.close()

        let stream = await coordinator.subscribeToRoutedEvents()
        let forwarded = Task<UInt64?, Never> {
            for await routed in stream {
                if routed.event == .turnCompleted(stopReason: "probe-done") {
                    return routed.sequence
                }
            }
            return nil
        }
        await backend.emit(.textDelta("late"), sessionID: session.id)
        await backend.emit(
            .sessionStarted(AgentSession(id: "resurrected", backendID: .claudeCode)),
            sessionID: session.id
        )
        await backend.emit(.turnCompleted(stopReason: "probe-done"), sessionID: session.id)
        let sequence = try #require(await forwarded.value)
        await controller.waitUntilRoutedSequenceConsumed(sequence)

        let state = await controller.stateSnapshot()
        #expect(state.isClosed)
        #expect(state.session?.id == session.id)
        #expect(state.stopReason == nil)
        #expect(state.assistantDraft.isEmpty)
        #expect(state.messages.map(\.content) == ["kept"])
    }

    @Test("resuming on another backend closes the previous backend session")
    func resumeSwitchesBackendAndClosesPrevious() async throws {
        let coordinator = AgentCoordinator()
        let claude = RecordingBackend(id: .claudeCode, displayName: "Claude Code")
        let hermes = RecordingBackend(id: .hermes, displayName: "Hermes")
        await coordinator.register(claude)
        await coordinator.register(hermes)
        let controller = AgentConversationController(coordinator: coordinator)

        let first = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        let hermesSession = AgentSession(
            id: "hermes-existing",
            backendID: .hermes,
            workingDirectory: nil
        )
        let resumed = try await controller.resumeSession(hermesSession)

        #expect(await claude.closed() == [first.id])
        #expect(await hermes.closed().isEmpty)
        #expect(resumed.backendID == .hermes)
        #expect(resumed.id == "hermes-existing")
        #expect((await controller.stateSnapshot()).session == resumed)
    }

    @Test("resume that returns a new session id closes the previous active session")
    func resumeMintedIdentityClosesPrevious() async throws {
        let coordinator = AgentCoordinator()
        let backend = RemintingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let first = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        let resumed = try await controller.resumeSession(first)

        #expect(first.id == "session-1")
        #expect(resumed.id == "session-1-live")
        #expect(await backend.closed() == ["session-1"])
        #expect((await controller.stateSnapshot()).session == resumed)
        #expect((await controller.stateSnapshot()).isClosed == false)
    }

    private actor RemintingBackend: AgentBackend {
        nonisolated let id: AgentID = .claudeCode
        nonisolated let displayName = "Reminting"
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions, .resume]
        nonisolated let events: AsyncStream<AgentEvent>
        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var closedSessions: [String] = []
        private var nextSessionNumber = 0

        init() {
            var continuation: AsyncStream<AgentEvent>.Continuation!
            events = AsyncStream { continuation = $0 }
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

        func resumeSession(_ session: AgentSession) async throws -> AgentSession {
            AgentSession(
                id: session.id + "-live",
                backendID: id,
                workingDirectory: session.workingDirectory,
                metadata: session.metadata
            )
        }

        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async { closedSessions.append(session.id) }
        func closed() -> [String] { closedSessions }
    }

    private actor ScopedRecordingBackend: SessionScopedAgentBackend {
        nonisolated let id: AgentID = .claudeCode
        nonisolated let displayName = "Scoped Claude"
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>
        nonisolated let sessionEvents: AsyncStream<AgentBackendEvent>

        private let eventContinuation: AsyncStream<AgentEvent>.Continuation
        private let sessionEventContinuation: AsyncStream<AgentBackendEvent>.Continuation
        private var closedSessions: [String] = []

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

        func close(session: AgentSession) async {
            closedSessions.append(session.id)
        }

        func emit(_ event: AgentEvent, sessionID: String) {
            eventContinuation.yield(event)
            sessionEventContinuation.yield(AgentBackendEvent(sessionID: sessionID, event: event))
        }

        func closed() -> [String] { closedSessions }
    }
}
