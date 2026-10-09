#if canImport(SQLite3)

import Foundation
import Testing
@testable import ScarfCore

@Suite struct HermesAgentConversationHistoryTests {
    private func makeRow(_ pairs: [(String, SQLValue)]) -> Row {
        var values: [SQLValue] = []
        var columnIndex: [String: Int] = [:]
        for (index, pair) in pairs.enumerated() {
            values.append(pair.1)
            columnIndex[pair.0] = index
        }
        return Row(values: values, columnIndex: columnIndex)
    }

    private func makeMessageRow(
        id: Int,
        sessionId: String,
        role: String,
        content: String
    ) -> Row {
        makeRow([
            ("id", .integer(Int64(id))),
            ("session_id", .text(sessionId)),
            ("role", .text(role)),
            ("content", .text(content)),
            ("tool_call_id", .null),
            ("tool_calls", .null),
            ("tool_name", .null),
            ("timestamp", .real(1_700_000_001.0)),
            ("token_count", .integer(10)),
            ("finish_reason", .null),
        ])
    }

    @Test("deterministic ids are stable for the same Hermes row")
    func deterministicIDs() {
        let first = HermesAgentConversationHistory.deterministicAgentMessageID(
            sessionID: "sess-a",
            hermesMessageID: 42
        )
        let second = HermesAgentConversationHistory.deterministicAgentMessageID(
            sessionID: "sess-a",
            hermesMessageID: 42
        )
        #expect(first == second)
    }

    @Test("fetchMessages maps state.db rows to agent messages in chronological order")
    func fetchFromMockBackend() async throws {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        _ = await service.open()

        let sessionID = "hermes-session-1"
        await mock._seedRows(
            forSQLPrefix: "SELECT id, session_id",
            [
                makeMessageRow(id: 2, sessionId: sessionID, role: "assistant", content: "Reply"),
                makeMessageRow(id: 1, sessionId: sessionID, role: "user", content: "Hello"),
            ]
        )

        let hermesMessages = await service.fetchMessages(sessionId: sessionID, limit: 10)
        let mapped = HermesAgentConversationHistory.mapHermesMessages(hermesMessages, sessionID: sessionID)

        #expect(mapped.count == 2)
        #expect(mapped[0].role == .user)
        #expect(mapped[0].content == "Hello")
        #expect(mapped[1].role == .assistant)
        #expect(mapped[1].content == "Reply")
        #expect(
            mapped[0].id
                == HermesAgentConversationHistory.deterministicAgentMessageID(
                    sessionID: sessionID,
                    hermesMessageID: 1
                )
        )
    }

    @Test("fetchMessages ignores rows from other sessions")
    func ignoresOtherSessions() async {
        let messages = [
            HermesMessage(
                id: 1,
                sessionId: "other",
                role: "user",
                content: "skip",
                toolCallId: nil,
                toolCalls: [],
                toolName: nil,
                timestamp: nil,
                tokenCount: nil,
                finishReason: nil,
                reasoning: nil
            ),
            HermesMessage(
                id: 2,
                sessionId: "target",
                role: "user",
                content: "keep",
                toolCallId: nil,
                toolCalls: [],
                toolName: nil,
                timestamp: nil,
                tokenCount: nil,
                finishReason: nil,
                reasoning: nil
            ),
        ]
        let mapped = HermesAgentConversationHistory.mapHermesMessages(messages, sessionID: "target")
        #expect(mapped.count == 1)
        #expect(mapped[0].content == "keep")
    }
}

#endif
