#if canImport(SQLite3)

import Foundation
import SQLite3
import Testing
@testable import ScarfCore

/// End-to-end restore through `restorePersistedSession` using a throwaway
/// Hermes `state.db` fixture: identity → Hermes history fetch → role+content
/// reconcile → Scarf durable activity retained.
@Suite("Agent conversation Hermes state.db restore")
struct AgentConversationHermesStateDBRestoreTests {

    private final class Fixture {
        let home: URL
        let sessionID: String
        private let dbPath: String

        init(sessionID: String = "hermes-session-restore-1") throws {
            self.sessionID = sessionID
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("scarf-hermes-restore-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            dbPath = home.appendingPathComponent("state.db").path

            try exec("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
                parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
                message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
                output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                estimated_cost_usd REAL
            );
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
                tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
                token_count INTEGER, finish_reason TEXT, reasoning TEXT,
                reasoning_content TEXT, active INTEGER NOT NULL DEFAULT 1,
                compacted INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO sessions (
                id, source, started_at, message_count, tool_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                estimated_cost_usd
            ) VALUES ('\(sessionID)', 'acp', 1700000000.0, 3, 0, 0, 0, 0, 0, 0.0);
            """)
        }

        var context: ServerContext { .local(home: home) }

        func insert(id: Int, role: String, content: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                throw TransportError.other(message: "sqlite3_open_v2 failed")
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO messages (
                id, session_id, role, content, timestamp, finish_reason, active, compacted
            ) VALUES (?, ?, ?, ?, ?, ?, 1, 0)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw TransportError.other(message: "prepare failed")
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int64(stmt, 1, Int64(id))
            sqlite3_bind_text(stmt, 2, sessionID, -1, transient)
            sqlite3_bind_text(stmt, 3, role, -1, transient)
            sqlite3_bind_text(stmt, 4, content, -1, transient)
            sqlite3_bind_double(stmt, 5, 1_700_000_000.0 + Double(id))
            if role == "assistant" {
                sqlite3_bind_text(stmt, 6, "stop", -1, transient)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw TransportError.other(message: "insert failed")
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: home)
        }

        private func exec(_ sql: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw TransportError.other(message: "sqlite3_open_v2 failed")
            }
            defer { sqlite3_close(db) }
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw TransportError.other(message: "fixture SQL failed: \(msg)")
            }
        }
    }

    @Test("restorePersistedSession loads fixture state.db, matches role+content, keeps Scarf activity")
    func restoreThroughFixtureStateDB() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.insert(id: 1, role: "user", content: "Hello from Scarf")
        try fixture.insert(id: 2, role: "assistant", content: "World from Scarf")
        try fixture.insert(id: 3, role: "assistant", content: "Extra only in Hermes")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-state-db-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        let scarfUserID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let scarfAssistantID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
        let hermesExtraID = HermesAgentConversationHistory.deterministicAgentMessageID(
            sessionID: fixture.sessionID,
            hermesMessageID: 3
        )

        try identityStore.save(
            AgentConversationIdentity(
                conversationID: "window-hermes-restore",
                backendID: .hermes,
                sessionID: fixture.sessionID
            )
        )
        try transcriptStore.save(
            AgentConversationTranscript(
                conversationID: "window-hermes-restore",
                messages: [
                    AgentMessage(id: scarfUserID, role: .user, content: "Hello from Scarf"),
                    AgentMessage(id: scarfAssistantID, role: .assistant, content: "World from Scarf"),
                ],
                toolCalls: [
                    AgentToolCall(id: "tool-scarf-durable", title: "Read", kind: "read", status: .completed),
                ],
                reasoningBlocks: ["kept across restore"]
            )
        )

        let coordinator = AgentCoordinator()
        let backend = FixtureHermesHistoryBackend(hermesHome: fixture.home)
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-hermes-restore",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )

        // Production path: no backendHistory override — must fetch from state.db.
        let session = try #require(await controller.restorePersistedSession())
        #expect(session.id == fixture.sessionID)
        #expect(session.backendID == .hermes)

        let after = await controller.stateSnapshot()
        #expect(after.messages.map(\.id) == [scarfUserID, scarfAssistantID, hermesExtraID])
        #expect(after.messages.map(\.content) == [
            "Hello from Scarf",
            "World from Scarf",
            "Extra only in Hermes",
        ])
        #expect(after.toolCalls.map(\.id) == ["tool-scarf-durable"])
        #expect(after.reasoningBlocks == ["kept across restore"])
        #expect(await backend.fetchCallCount() == 1)
        #expect(await backend.lastFetchedSessionID() == fixture.sessionID)
    }

    /// Thin Hermes-shaped backend that loads history via the real
    /// `HermesAgentConversationHistory` → `HermesDataService` state.db path.
    private actor FixtureHermesHistoryBackend: AgentBackend {
        nonisolated let id: AgentID = .hermes
        nonisolated let displayName = "Hermes"
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions, .resume]
        nonisolated let events: AsyncStream<AgentEvent>
        private let continuation: AsyncStream<AgentEvent>.Continuation
        private let hermesHome: URL
        private var fetchCalls = 0
        private var lastSessionID: String?

        init(hermesHome: URL) {
            self.hermesHome = hermesHome
            var continuation: AsyncStream<AgentEvent>.Continuation!
            self.events = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus { .available(version: nil) }
        nonisolated func models() async throws -> [AgentModel] { [] }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            AgentSession(
                id: "hermes-new",
                backendID: id,
                workingDirectory: configuration.workingDirectory
            )
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession { session }

        func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage] {
            fetchCalls += 1
            lastSessionID = session.id
            return try await HermesAgentConversationHistory.fetchMessages(
                sessionID: session.id,
                context: .local(home: hermesHome)
            )
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

#endif
