import Foundation
import Testing
@testable import ScarfCore

/// Phase 4 wiring: permissionRequested enqueues into the coordinator owned by
/// conversation state; respond/cancel resolve through it while Hermes ACP
/// numeric ids stay intact for the backend wire path.
@Suite("Agent conversation permission wiring")
struct AgentConversationPermissionWiringTests {

    private actor PermissionRecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities
        nonisolated let events: AsyncStream<AgentEvent>

        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var respondCalls: [(request: AgentPermissionRequest, optionID: String, sessionID: String)] = []
        private var cancelCalls: [(request: AgentPermissionRequest, sessionID: String)] = []
        private var nextSessionNumber = 0

        init(
            id: AgentID = .hermes,
            displayName: String = "Hermes",
            capabilities: AgentCapabilities = [.streaming, .sessions, .permissions]
        ) {
            self.id = id
            self.displayName = displayName
            self.capabilities = capabilities
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
        func send(_ message: AgentMessage, in session: AgentSession) async throws {}

        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {
            respondCalls.append((request, optionID, session.id))
        }

        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {
            cancelCalls.append((request, session.id))
        }

        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func emit(_ event: AgentEvent) {
            continuation.yield(event)
        }

        func responded() -> [(request: AgentPermissionRequest, optionID: String, sessionID: String)] {
            respondCalls
        }

        func cancelledPermissions() -> [(request: AgentPermissionRequest, sessionID: String)] {
            cancelCalls
        }
    }

    private func hermesPermission(
        id: String = "42",
        title: String = "run: ls",
        detail: String = "execute"
    ) -> AgentPermissionRequest {
        AgentPermissionRequest(
            id: id,
            title: title,
            detail: detail,
            options: [
                AgentPermissionOption(id: "allow_once", title: "Allow once"),
                AgentPermissionOption(id: "deny", title: "Deny"),
            ]
        )
    }

    @Test("permissionRequested event enqueues pending permission in coordinator and state")
    func permissionRequestedEnqueuesPending() async throws {
        let coordinator = AgentCoordinator()
        let backend = PermissionRecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let session = try await controller.startSession(
            backendID: .hermes,
            configuration: AgentSessionConfiguration()
        )

        let request = hermesPermission()
        let pending = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.permissionCoordinator.pending.contains(where: { $0.id == "42" }) {
                    return state
                }
            }
            return nil
        }

        await backend.emit(.permissionRequested(request))
        let state = try #require(await pending.value)

        #expect(state.permissionRequest == request)
        #expect(state.permissionCoordinator.pending.map(\.id) == ["42"])
        #expect(state.permissionCoordinator.presented?.id == "42")
        #expect(state.permissionCoordinator.presented?.backendID == .hermes)
        #expect(state.permissionCoordinator.presented?.sessionID == session.id)
        #expect(state.permissionCoordinator.presented?.description == "run: ls")
        #expect(state.permissionCoordinator.presented?.category == "execute")
        #expect(state.permissionCoordinator.presented?.options.map(\.id) == ["allow_once", "deny"])
        #expect(state.permissionCoordinator.presented?.status == .pending)
    }

    @Test("respond answers pending permission through coordinator and forwards Hermes wire id")
    func respondAnswersAndForwardsHermesWireID() async throws {
        let coordinator = AgentCoordinator()
        let backend = PermissionRecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        _ = try await controller.startSession(
            backendID: .hermes,
            configuration: AgentSessionConfiguration()
        )

        let request = hermesPermission(id: "42")
        let second = hermesPermission(id: "43", title: "run: pwd")
        let queued = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.permissionCoordinator.pending.map(\.id) == ["42", "43"] {
                    return state
                }
            }
            return nil
        }
        await backend.emit(.permissionRequested(request))
        await backend.emit(.permissionRequested(second))
        _ = try #require(await queued.value)

        try await controller.respond(to: request, optionID: "allow_once")

        let state = await controller.stateSnapshot()
        #expect(state.permissionCoordinator.pending.map(\.id) == ["43"])
        #expect(state.permissionCoordinator.presented?.id == "43")
        #expect(state.permissionRequest?.id == "43")
        #expect(state.permissionCoordinator.records.first { $0.id == "42" }?.status == .answered)
        #expect(state.permissionCoordinator.records.first { $0.id == "42" }?.selectedOptionID == "allow_once")

        let calls = await backend.responded()
        #expect(calls.count == 1)
        #expect(calls[0].request.id == "42")
        #expect(Int(calls[0].request.id) == 42)
        #expect(calls[0].optionID == "allow_once")
        #expect(calls[0].request.options.map(\.id) == ["allow_once", "deny"])
        #expect(calls[0].request == request)
    }

    @Test("cancelPermission cancels pending through coordinator and forwards Hermes wire id")
    func cancelCancelsAndForwardsHermesWireID() async throws {
        let coordinator = AgentCoordinator()
        let backend = PermissionRecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        _ = try await controller.startSession(
            backendID: .hermes,
            configuration: AgentSessionConfiguration()
        )

        let request = hermesPermission(id: "7", title: "run: curl")
        let pending = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.permissionCoordinator.pending.contains(where: { $0.id == "7" }) {
                    return state
                }
            }
            return nil
        }
        await backend.emit(.permissionRequested(request))
        _ = try #require(await pending.value)

        try await controller.cancelPermission(request)

        let state = await controller.stateSnapshot()
        #expect(state.permissionCoordinator.pending.isEmpty)
        #expect(state.permissionRequest == nil)
        #expect(state.permissionCoordinator.records.first { $0.id == "7" }?.status == .cancelled)
        #expect(state.permissionCoordinator.records.first { $0.id == "7" }?.selectedOptionID == nil)

        let calls = await backend.cancelledPermissions()
        #expect(calls.count == 1)
        #expect(calls[0].request.id == "7")
        #expect(Int(calls[0].request.id) == 7)
        #expect(calls[0].request == request)
    }

    @Test("Hermes permission record round-trips ACP ids used by controller respond")
    func hermesIDMappingIntactThroughControllerRespond() async throws {
        let coordinator = AgentCoordinator()
        let backend = PermissionRecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let session = try await controller.startSession(
            backendID: .hermes,
            configuration: AgentSessionConfiguration()
        )

        let request = hermesPermission(id: "99", title: "run: echo")
        let pending = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if let presented = state.permissionCoordinator.presented, presented.id == "99" {
                    return state
                }
            }
            return nil
        }
        await backend.emit(.permissionRequested(request))
        let before = try #require(await pending.value)
        let record = try #require(before.permissionCoordinator.presented)
        #expect(record.backendID == .hermes)
        #expect(record.sessionID == session.id)
        #expect(record.asAgentPermissionRequest == request)
        #expect(Int(record.asAgentPermissionRequest.id) == 99)

        try await controller.respond(to: record.asAgentPermissionRequest, optionID: "deny")

        let calls = await backend.responded()
        #expect(calls.count == 1)
        #expect(calls[0].request.id == "99")
        #expect(Int(calls[0].request.id) == 99)
        #expect(calls[0].optionID == "deny")

        let after = await controller.stateSnapshot()
        #expect(after.permissionCoordinator.pending.isEmpty)
        #expect(after.permissionCoordinator.records.first?.status == .answered)
        #expect(after.permissionCoordinator.records.first?.selectedOptionID == "deny")
    }
}
