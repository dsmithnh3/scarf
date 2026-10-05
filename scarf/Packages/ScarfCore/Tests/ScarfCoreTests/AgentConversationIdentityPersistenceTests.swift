import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation identity persistence")
struct AgentConversationIdentityStoreTests {
    @Test("started session identity survives a store reload boundary")
    func startPersistsAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")

        let writer = AgentConversationIdentityStore(fileURL: fileURL)
        let identity = AgentConversationIdentity(
            conversationID: "conv-1",
            backendID: .claudeCode,
            sessionID: "session-a",
            workingDirectoryPath: "/tmp/project"
        )
        try writer.save(identity)

        let reader = AgentConversationIdentityStore(fileURL: fileURL)
        let maybeLoaded = try reader.load(conversationID: "conv-1")
        let loaded = try #require(maybeLoaded)
        #expect(loaded.conversationID == "conv-1")
        #expect(loaded.backendID == .claudeCode)
        #expect(loaded.sessionID == "session-a")
        #expect(loaded.workingDirectoryPath == "/tmp/project")
    }

    @Test("remove clears identity so a reload finds nothing")
    func removeClearsAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-identity-rm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")

        let writer = AgentConversationIdentityStore(fileURL: fileURL)
        try writer.save(
            AgentConversationIdentity(
                conversationID: "conv-1",
                backendID: .hermes,
                sessionID: "session-h"
            )
        )
        try writer.remove(conversationID: "conv-1")

        let reader = AgentConversationIdentityStore(fileURL: fileURL)
        #expect(try reader.load(conversationID: "conv-1") == nil)
    }
}

@Suite("Agent conversation controller identity persistence")
struct AgentConversationControllerIdentityPersistenceTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>

        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var closedSessions: [String] = []
        private var resumedSessions: [AgentSession] = []
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

        func resumeSession(_ session: AgentSession) async throws -> AgentSession {
            resumedSessions.append(session)
            return session
        }

        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {
            closedSessions.append(session.id)
        }

        func resumed() -> [AgentSession] { resumedSessions }
        func closed() -> [String] { closedSessions }
    }

    @Test("startSession persists backend and session id for later restore")
    func startPersistsIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let store = AgentConversationIdentityStore(fileURL: fileURL)

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: store
        )
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let session = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(workingDirectory: cwd)
        )

        let reloaded = AgentConversationIdentityStore(fileURL: fileURL)
        let maybeIdentity = try reloaded.load(conversationID: "window-1")
        let identity = try #require(maybeIdentity)
        #expect(identity.backendID == .claudeCode)
        #expect(identity.sessionID == session.id)
        #expect(identity.workingDirectoryPath == cwd.path)
    }

    @Test("restorePersistedSession resumes the stored backend and session id")
    func restoreResumesStoredIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let store = AgentConversationIdentityStore(fileURL: fileURL)

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)

        let first = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: store
        )
        let started = try await first.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp/project")
            )
        )
        // Relaunch without close: identity must still be on disk for restore.

        let reloadedStore = AgentConversationIdentityStore(fileURL: fileURL)
        let second = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: reloadedStore
        )
        let restored = try #require(await second.restorePersistedSession())
        #expect(restored.id == started.id)
        #expect(restored.backendID == .claudeCode)

        let resumed = await backend.resumed()
        #expect(resumed.map(\.id) == [started.id])
    }

    @Test("resumeSession updates the persisted session identity")
    func resumeUpdatesPersistedIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let store = AgentConversationIdentityStore(fileURL: fileURL)

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: store
        )
        _ = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        let other = AgentSession(id: "session-resumed", backendID: .claudeCode)
        _ = try await controller.resumeSession(other)

        let reloaded = AgentConversationIdentityStore(fileURL: fileURL)
        let maybeIdentity = try reloaded.load(conversationID: "window-1")
        let identity = try #require(maybeIdentity)
        #expect(identity.sessionID == "session-resumed")
        #expect(identity.backendID == .claudeCode)
    }

    @Test("close removes persisted identity")
    func closeRemovesIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let store = AgentConversationIdentityStore(fileURL: fileURL)

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: store
        )
        _ = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        try await controller.close()

        let reloaded = AgentConversationIdentityStore(fileURL: fileURL)
        #expect(try reloaded.load(conversationID: "window-1") == nil)
    }
}
