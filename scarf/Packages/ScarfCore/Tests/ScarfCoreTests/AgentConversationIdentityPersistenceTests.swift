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

    @Test("undecodable identity sidecar refuses overwrite and preserves bytes")
    func corruptIdentityRefusesSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-identity-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let garbage = Data("{ not-identity-json".utf8)
        try garbage.write(to: fileURL)

        let store = AgentConversationIdentityStore(fileURL: fileURL)
        #expect(AgentConversationIdentityStore.damagePolicy == .refuseForever)
        #expect(throws: GuardedStoreError.refusedUnreadableOverwrite(
            path: fileURL.path,
            label: AgentConversationIdentityStore.label
        )) {
            try store.save(
                AgentConversationIdentity(
                    conversationID: "conv-1",
                    backendID: .hermes,
                    sessionID: "session-h"
                )
            )
        }
        #expect(try Data(contentsOf: fileURL) == garbage)
    }

    @Test("identity overwrite refreshes one-deep bak via guarded publish")
    func identityOverwriteKeepsBak() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-identity-bak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let store = AgentConversationIdentityStore(fileURL: fileURL)

        try store.save(
            AgentConversationIdentity(
                conversationID: "conv-1",
                backendID: .hermes,
                sessionID: "session-a"
            )
        )
        let firstBytes = try Data(contentsOf: fileURL)
        try store.save(
            AgentConversationIdentity(
                conversationID: "conv-1",
                backendID: .hermes,
                sessionID: "session-b"
            )
        )

        let bakURL = URL(fileURLWithPath: fileURL.path + ".bak")
        #expect(FileManager.default.fileExists(atPath: bakURL.path))
        #expect(try Data(contentsOf: bakURL) == firstBytes)
        let loaded = try #require(try store.load(conversationID: "conv-1"))
        #expect(loaded.sessionID == "session-b")
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

@Suite("Agent conversation identity production wiring")
struct AgentConversationIdentityProductionWiringTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>

        private let continuation: AsyncStream<AgentEvent>.Continuation
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
        func close(session: AgentSession) async {}

        func resumed() -> [AgentSession] { resumedSessions }
    }

    @Test("productionFileURL matches HermesPathSet.agentConversationIdentities layout")
    func productionFileURLMatchesHermesPathSetLayout() {
        let hermesHome = "/tmp/fake-hermes-home"
        let url = AgentConversationIdentityStore.productionFileURL(hermesHome: hermesHome)
        #expect(url.path == hermesHome + "/scarf/agent_conversation_identities.json")
    }

    @Test("makePersisting bootstrap writes and restores via HermesPathSet production location")
    func makePersistingPersistsAndRestoresAtProductionPath() async throws {
        let hermesHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-prod-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hermesHome) }
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)

        let expectedURL = AgentConversationIdentityStore.productionFileURL(
            hermesHome: hermesHome.path
        )
        #expect(expectedURL.path.hasSuffix("/scarf/agent_conversation_identities.json"))

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)

        let conversationID = UUID().uuidString
        let controller = AgentConversationController.makePersisting(
            coordinator: coordinator,
            conversationID: conversationID,
            hermesHome: hermesHome.path
        )
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let started = try await controller.startOrRestorePersistedSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(workingDirectory: cwd)
        )

        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        let onDisk = try AgentConversationIdentityStore(fileURL: expectedURL)
            .load(conversationID: conversationID)
        let identity = try #require(onDisk)
        #expect(identity.backendID == .claudeCode)
        #expect(identity.sessionID == started.id)
        #expect(identity.workingDirectoryPath == cwd.path)

        // Relaunch seam: new controller from the same production factory
        // restores the stored backend + session without a second state system.
        let relaunched = AgentConversationController.makePersisting(
            coordinator: coordinator,
            conversationID: conversationID,
            hermesHome: hermesHome.path
        )
        let restored = try await relaunched.startOrRestorePersistedSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(workingDirectory: cwd)
        )
        // startOrRestore should resume, not mint a second session.
        #expect(restored.id == started.id)
        #expect(restored.backendID == .claudeCode)
        let resumed = await backend.resumed()
        #expect(resumed.map(\.id) == [started.id])
    }
}
