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

    @Test("same role and content with different ids do not duplicate; Scarf ids and activity win")
    func crossSourceRoleContentMatchKeepsScarf() {
        // Scarf durable UUIDs vs Hermes-derived deterministic ids for the same turns.
        let scarfUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let scarfAssistantID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        // Stand-ins for HermesAgentConversationHistory.deterministicAgentMessageID
        // (different id scheme; must not match Scarf UUIDs).
        let hermesUserID = UUID(uuidString: "8f4e2c1a-5b6d-4e7f-9a0b-000000000001")!
        let hermesAssistantID = UUID(uuidString: "8f4e2c1a-5b6d-4e7f-9a0b-000000000002")!
        #expect(scarfUserID != hermesUserID)
        #expect(scarfAssistantID != hermesAssistantID)

        let scarf = AgentConversationTranscript(
            conversationID: "conv-1",
            messages: [
                AgentMessage(id: scarfUserID, role: .user, content: "Hello"),
                AgentMessage(id: scarfAssistantID, role: .assistant, content: "Hi there"),
            ],
            toolResults: [
                "tool-1": AgentToolResult(toolCallID: "tool-1", status: .completed, output: "ok"),
            ],
            usage: AgentUsage(inputTokens: 3, outputTokens: 4, reasoningTokens: 1, cachedReadTokens: 0),
            toolCalls: [
                AgentToolCall(id: "tool-1", title: "Read", kind: "read", status: .completed),
            ],
            commands: [
                AgentCommand(id: "cmd-1", command: "ls", status: .completed),
            ],
            commandOutput: ["cmd-1": "file.txt"],
            reasoningBlocks: ["scarf-thinking"]
        )

        let backendHistory = [
            AgentMessage(id: hermesUserID, role: .user, content: "Hello"),
            AgentMessage(id: hermesAssistantID, role: .assistant, content: "Hi there"),
        ]

        let reconciled = scarf.reconciling(withBackendHistory: backendHistory)

        #expect(reconciled.messages.count == 2)
        #expect(reconciled.messages.map(\.id) == [scarfUserID, scarfAssistantID])
        #expect(reconciled.messages.map(\.content) == ["Hello", "Hi there"])
        #expect(reconciled.toolCalls.map(\.id) == ["tool-1"])
        #expect(reconciled.toolResults["tool-1"]?.output == "ok")
        #expect(reconciled.commands.map(\.id) == ["cmd-1"])
        #expect(reconciled.commandOutput["cmd-1"] == "file.txt")
        #expect(reconciled.reasoningBlocks == ["scarf-thinking"])
        #expect(reconciled.usage?.inputTokens == 3)
    }

    @Test("role+content collision keeps Scarf content when backend text differs for same turn pair")
    func crossSourceMatchPrefersScarfContentOnAmbiguousPair() {
        // After id miss, a later backend-only distinct turn still appends;
        // matched role+content keeps Scarf wording (not backend overwrite).
        let scarfUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let scarfAssistantID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let hermesUserID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000001")!
        let hermesAssistantID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000002")!
        let hermesExtraID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000003")!

        let scarf = AgentConversationTranscript(
            conversationID: "conv-1",
            messages: [
                AgentMessage(id: scarfUserID, role: .user, content: "Scarf user text"),
                AgentMessage(id: scarfAssistantID, role: .assistant, content: "Shared reply"),
            ],
            toolCalls: [
                AgentToolCall(id: "tool-scarf", title: "Keep", kind: "read", status: .completed),
            ]
        )

        let backendHistory = [
            AgentMessage(id: hermesUserID, role: .user, content: "Scarf user text"),
            AgentMessage(id: hermesAssistantID, role: .assistant, content: "Shared reply"),
            AgentMessage(id: hermesExtraID, role: .assistant, content: "Backend-only extra"),
        ]

        let reconciled = scarf.reconciling(withBackendHistory: backendHistory)

        #expect(reconciled.messages.map(\.id) == [scarfUserID, scarfAssistantID, hermesExtraID])
        #expect(reconciled.messages.map(\.content) == [
            "Scarf user text",
            "Shared reply",
            "Backend-only extra",
        ])
        #expect(reconciled.toolCalls.map(\.id) == ["tool-scarf"])
    }

    @Test("distinct role or content still appends after unmatched id pass")
    func distinctCrossSourceMessagesStillAppend() {
        let scarfUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let hermesOtherID = UUID(uuidString: "bbbbbbbb-bbbb-cccc-dddd-000000000001")!
        let hermesSameRoleDiffContent = UUID(uuidString: "bbbbbbbb-bbbb-cccc-dddd-000000000002")!

        let scarf = AgentConversationTranscript(
            conversationID: "conv-1",
            messages: [
                AgentMessage(id: scarfUserID, role: .user, content: "Hello"),
            ]
        )

        let backendHistory = [
            AgentMessage(id: hermesOtherID, role: .assistant, content: "Hello"), // same content, different role
            AgentMessage(id: hermesSameRoleDiffContent, role: .user, content: "Goodbye"), // same role, different content
        ]

        let reconciled = scarf.reconciling(withBackendHistory: backendHistory)

        #expect(reconciled.messages.map(\.id) == [scarfUserID, hermesOtherID, hermesSameRoleDiffContent])
        #expect(reconciled.messages.map(\.content) == ["Hello", "Hello", "Goodbye"])
        #expect(reconciled.messages.map(\.role) == [.user, .assistant, .user])
    }

    @Test("repeated identical role+content pairs match greedily without double-consuming Scarf turns")
    func repeatedRoleContentMatchesGreedily() {
        let scarfFirst = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let scarfSecond = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let hermesFirst = UUID(uuidString: "cccccccc-bbbb-cccc-dddd-000000000001")!
        let hermesSecond = UUID(uuidString: "cccccccc-bbbb-cccc-dddd-000000000002")!
        let hermesThird = UUID(uuidString: "cccccccc-bbbb-cccc-dddd-000000000003")!

        let scarf = AgentConversationTranscript(
            conversationID: "conv-1",
            messages: [
                AgentMessage(id: scarfFirst, role: .user, content: "ping"),
                AgentMessage(id: scarfSecond, role: .user, content: "ping"),
            ]
        )

        let backendHistory = [
            AgentMessage(id: hermesFirst, role: .user, content: "ping"),
            AgentMessage(id: hermesSecond, role: .user, content: "ping"),
            AgentMessage(id: hermesThird, role: .user, content: "ping"),
        ]

        let reconciled = scarf.reconciling(withBackendHistory: backendHistory)

        #expect(reconciled.messages.map(\.id) == [scarfFirst, scarfSecond, hermesThird])
        #expect(reconciled.messages.map(\.content) == ["ping", "ping", "ping"])
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

        // `consume` publishes state before persisting the transcript, so a
        // second controller can race an in-flight save. Wait until the durable
        // snapshot includes the assistant turn before restoring.
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)
        var persistedContents: [String] = []
        var persistedToolIDs: [String] = []
        for _ in 0..<100 {
            if let loaded = try transcriptStore.load(conversationID: "window-1") {
                persistedContents = loaded.messages.map(\.content)
                persistedToolIDs = loaded.toolCalls.map(\.id)
                if persistedContents == ["Hello", "World"], persistedToolIDs == ["tool-1"] {
                    break
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(persistedContents == ["Hello", "World"])
        #expect(persistedToolIDs == ["tool-1"])

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

    @Test("restorePersistedSession matches cross-source role+content without duplicating")
    func restoreMatchesCrossSourceRoleContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-history-cross-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        let scarfUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let scarfAssistantID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let hermesUserID = UUID(uuidString: "8f4e2c1a-5b6d-4e7f-9a0b-000000000031")!
        let hermesAssistantID = UUID(uuidString: "8f4e2c1a-5b6d-4e7f-9a0b-000000000032")!
        let hermesExtraID = UUID(uuidString: "8f4e2c1a-5b6d-4e7f-9a0b-000000000033")!

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
                messages: [
                    AgentMessage(id: scarfUserID, role: .user, content: "Hello"),
                    AgentMessage(id: scarfAssistantID, role: .assistant, content: "World"),
                ],
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
                    AgentMessage(id: hermesUserID, role: .user, content: "Hello"),
                    AgentMessage(id: hermesAssistantID, role: .assistant, content: "World"),
                    AgentMessage(id: hermesExtraID, role: .assistant, content: "Extra from Hermes"),
                ]
            )
        )

        let after = await controller.stateSnapshot()
        #expect(after.messages.map(\.id) == [scarfUserID, scarfAssistantID, hermesExtraID])
        #expect(after.messages.map(\.content) == ["Hello", "World", "Extra from Hermes"])
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
