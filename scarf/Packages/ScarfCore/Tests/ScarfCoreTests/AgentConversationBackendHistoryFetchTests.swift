import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation backend-history fetch wiring")
struct AgentConversationBackendHistoryFetchTests {
    @Test("coordinator routes fetchConversationHistory to the session backend")
    func coordinatorRoutesFetchHistory() async throws {
        let coordinator = AgentCoordinator()
        let backend = HistoryProvidingBackend(
            history: [
                AgentMessage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
                    role: .user,
                    content: "From backend"
                ),
            ]
        )
        await coordinator.register(backend)

        let session = AgentSession(id: "session-1", backendID: .claudeCode)
        let history = try await coordinator.fetchConversationHistory(for: session)

        #expect(history.map(\.content) == ["From backend"])
        #expect(await backend.fetchCallCount() == 1)
        #expect(await backend.lastFetchedSessionID() == "session-1")
    }

    @Test("restorePersistedSession fetches backend history and reconciles")
    func restoreFetchesAndReconcilesBackendHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-history-fetch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let scarfUser = AgentMessage(id: sharedID, role: .user, content: "Scarf user")
        let backendOnly = AgentMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
            role: .assistant,
            content: "Fetched backend only"
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
        let backend = HistoryProvidingBackend(
            history: [
                AgentMessage(id: sharedID, role: .user, content: "Backend overwrite attempt"),
                backendOnly,
            ]
        )
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )

        // No explicit backendHistory override — production path must fetch.
        _ = try #require(await controller.restorePersistedSession())

        let after = await controller.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Scarf user", "Fetched backend only"])
        #expect(after.messages.map(\.id) == [sharedID, backendOnly.id])
        #expect(after.toolCalls.map(\.id) == ["tool-scarf"])
        #expect(await backend.fetchCallCount() == 1)
        #expect(await backend.lastFetchedSessionID() == "session-1")
    }

    @Test("startOrRestorePersistedSession fetches history on restore")
    func startOrRestoreFetchesHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-history-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        let backendOnly = AgentMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
            role: .assistant,
            content: "Adopted from backend"
        )
        try identityStore.save(
            AgentConversationIdentity(
                conversationID: "window-2",
                backendID: .claudeCode,
                sessionID: "session-2"
            )
        )
        // Empty Scarf messages → reconcile adopts backend.
        try transcriptStore.save(
            AgentConversationTranscript(
                conversationID: "window-2",
                messages: [],
                toolCalls: [
                    AgentToolCall(id: "tool-local", title: "Local", kind: "read", status: .completed),
                ]
            )
        )

        let coordinator = AgentCoordinator()
        let backend = HistoryProvidingBackend(history: [backendOnly])
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-2",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )

        _ = try await controller.startOrRestorePersistedSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        )

        let after = await controller.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Adopted from backend"])
        #expect(after.toolCalls.map(\.id) == ["tool-local"])
        #expect(await backend.fetchCallCount() == 1)
    }

    @Test("explicit backendHistory override skips fetch")
    func explicitOverrideSkipsFetch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-history-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        try identityStore.save(
            AgentConversationIdentity(
                conversationID: "window-3",
                backendID: .claudeCode,
                sessionID: "session-3"
            )
        )
        try transcriptStore.save(
            AgentConversationTranscript(
                conversationID: "window-3",
                messages: [
                    AgentMessage(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
                        role: .user,
                        content: "Scarf"
                    ),
                ]
            )
        )

        let coordinator = AgentCoordinator()
        let backend = HistoryProvidingBackend(
            history: [
                AgentMessage(role: .assistant, content: "Should not be fetched"),
            ]
        )
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-3",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )

        _ = try #require(await controller.restorePersistedSession(backendHistory: []))

        let after = await controller.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Scarf"])
        #expect(await backend.fetchCallCount() == 0)
    }

    private actor HistoryProvidingBackend: AgentBackend {
        nonisolated let id: AgentID = .claudeCode
        nonisolated let displayName = "Claude Code"
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions, .resume]
        nonisolated let events: AsyncStream<AgentEvent>
        private let continuation: AsyncStream<AgentEvent>.Continuation
        private let history: [AgentMessage]
        private var fetchCalls = 0
        private var lastSessionID: String?

        init(history: [AgentMessage]) {
            self.history = history
            var continuation: AsyncStream<AgentEvent>.Continuation!
            self.events = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus { .available(version: nil) }
        nonisolated func models() async throws -> [AgentModel] { [] }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            AgentSession(
                id: "session-new",
                backendID: id,
                workingDirectory: configuration.workingDirectory
            )
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession { session }

        func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage] {
            fetchCalls += 1
            lastSessionID = session.id
            return history
        }

        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func fetchCallCount() -> Int { fetchCalls }
        func lastFetchedSessionID() -> String? { lastSessionID }
    }
}
