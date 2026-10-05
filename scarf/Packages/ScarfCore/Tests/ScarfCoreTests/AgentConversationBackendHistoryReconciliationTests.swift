import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation backend-history reconciliation")
struct AgentConversationBackendHistoryReconciliationTests {
    @Test("empty backend history prefers Scarf transcript including activity")
    func emptyBackendPrefersScarf() {
        let tool = AgentToolCall(id: "tool-1", title: "Read", kind: "read", status: .completed)
        let scarf = AgentConversationTranscript(
            conversationID: "conv-1",
            messages: [
                AgentMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, role: .user, content: "Hello"),
                AgentMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, role: .assistant, content: "Hi"),
            ],
            toolResults: [
                "tool-1": AgentToolResult(toolCallID: "tool-1", status: .completed, output: "ok"),
            ],
            usage: AgentUsage(inputTokens: 1, outputTokens: 2, reasoningTokens: 0, cachedReadTokens: 0),
            toolCalls: [tool],
            reasoningBlocks: ["thinking"]
        )

        let reconciled = scarf.reconciling(withBackendHistory: [])

        #expect(reconciled == scarf)
    }

    @Test("empty Scarf messages adopt backend history and keep Scarf activity")
    func emptyScarfAdoptsBackendMessages() {
        let backendOnly = AgentMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
            role: .user,
            content: "From backend"
        )
        let tool = AgentToolCall(id: "tool-local", title: "Scarf-only", kind: "read", status: .completed)
        let scarf = AgentConversationTranscript(
            conversationID: "conv-1",
            messages: [],
            toolCalls: [tool],
            reasoningBlocks: ["local-only"]
        )

        let reconciled = scarf.reconciling(withBackendHistory: [backendOnly])

        #expect(reconciled.messages == [backendOnly])
        #expect(reconciled.toolCalls == [tool])
        #expect(reconciled.reasoningBlocks == ["local-only"])
        #expect(reconciled.conversationID == "conv-1")
    }

    @Test("overlapping message ids keep Scarf content and do not duplicate")
    func overlappingIdsPreferScarfContent() {
        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let scarfMessage = AgentMessage(id: sharedID, role: .user, content: "Scarf text")
        let backendMessage = AgentMessage(id: sharedID, role: .user, content: "Backend text")
        let scarfOnlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let scarfOnly = AgentMessage(id: scarfOnlyID, role: .assistant, content: "Scarf reply")
        let backendOnlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let backendOnly = AgentMessage(id: backendOnlyID, role: .assistant, content: "Backend-only")

        let scarf = AgentConversationTranscript(
            conversationID: "conv-1",
            messages: [scarfMessage, scarfOnly],
            toolCalls: [
                AgentToolCall(id: "tool-1", title: "Keep me", kind: "read", status: .completed),
            ]
        )

        let reconciled = scarf.reconciling(withBackendHistory: [backendMessage, backendOnly])

        #expect(reconciled.messages.map(\.id) == [sharedID, scarfOnlyID, backendOnlyID])
        #expect(reconciled.messages.map(\.content) == ["Scarf text", "Scarf reply", "Backend-only"])
        #expect(reconciled.toolCalls.map(\.id) == ["tool-1"])
    }

    @Test("restorePersistedSession reconciles empty backend history to Scarf snapshot")
    func restoreWithEmptyBackendHistoryKeepsScarf() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-history-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")

        let coordinator = AgentCoordinator()
        let backend = HistoryRecordingBackend()
        await coordinator.register(backend)

        let first = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )
        let started = try await first.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        )
        try await first.send("Hello")

        let completed = Task<AgentConversationState?, Never> {
            for await state in first.stateUpdates {
                if state.messages.map(\.content) == ["Hello", "World"],
                   state.toolCalls.map(\.id) == ["tool-1"] {
                    return state
                }
            }
            return nil
        }
        await backend.emit(
            .toolStarted(
                AgentToolCall(id: "tool-1", title: "Read", kind: "read", status: .completed)
            )
        )
        await backend.emit(.textDelta("World"))
        await backend.emit(.textCompleted)
        await backend.emit(.turnCompleted(stopReason: "end_turn"))
        _ = try #require(await completed.value)
        _ = started

        let second = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )
        _ = try #require(await second.restorePersistedSession(backendHistory: []))

        let after = await second.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Hello", "World"])
        #expect(after.toolCalls.map(\.id) == ["tool-1"])
    }

    @Test("restorePersistedSession merges backend-only message ids after Scarf")
    func restoreMergesBackendOnlyIds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-history-merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let scarfUser = AgentMessage(id: sharedID, role: .user, content: "Scarf user")
        let backendOnly = AgentMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            role: .assistant,
            content: "Backend only"
        )
        try identityStore.save(
            AgentConversationIdentity(
                conversationID: "window-1",
                backendID: .claudeCode,
                sessionID: "session-1"
            )
        )
        try transcriptStore.save(
            AgentConversationTranscript(
                conversationID: "window-1",
                messages: [scarfUser],
                toolCalls: [
                    AgentToolCall(id: "tool-scarf", title: "Keep", kind: "read", status: .completed),
                ]
            )
        )

        let coordinator = AgentCoordinator()
        let backend = HistoryRecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )

        _ = try #require(
            await controller.restorePersistedSession(
                backendHistory: [
                    AgentMessage(id: sharedID, role: .user, content: "Backend overwrite attempt"),
                    backendOnly,
                ]
            )
        )

        let after = await controller.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Scarf user", "Backend only"])
        #expect(after.messages.map(\.id) == [sharedID, backendOnly.id])
        #expect(after.toolCalls.map(\.id) == ["tool-scarf"])
    }

    private final class HistoryRecordingBackend: AgentBackend, @unchecked Sendable {
        let id: AgentID = .claudeCode
        let displayName = "Claude Code"
        let capabilities: AgentCapabilities = [.streaming, .sessions, .resume]
        let events: AsyncStream<AgentEvent>
        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var nextSessionNumber = 0

        init() {
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
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func emit(_ event: AgentEvent) {
            continuation.yield(event)
        }
    }
}
