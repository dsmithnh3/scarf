import CryptoKit
import Foundation

/// Read-only Hermes `state.db` transcript rows mapped to generic agent messages.
///
/// Uses the same `HermesDataService.fetchMessages` path as Rich Chat history
/// loads (C3 read-only via `HermesQueryBackend`). Does not start ACP or alter
/// session lifecycle.
///
/// Message ids are deterministic from `(sessionID, Hermes row id)` so repeated
/// fetches are stable. They will **not** match Scarf-owned random UUIDs on
/// restore; reconcile still merges by id only (cross-source matching remains a
/// separate product decision).
public enum HermesAgentConversationHistory {
    /// Namespace for deterministic `AgentMessage.id` values derived from Hermes rows.
    private static let messageIDNamespace = UUID(uuidString: "8f4e2c1a-5b6d-4e7f-9a0b-1c2d3e4f5a6b")!

    /// Maximum rows loaded for backend history (matches reconnect reconcile budget).
    public nonisolated static let fetchLimit = HistoryPageSize.reconcile

    /// Load structured messages for a Hermes session id from the configured host's `state.db`.
    public static func fetchMessages(
        sessionID: String,
        context: ServerContext = .local
    ) async throws -> [AgentMessage] {
        let service = HermesDataService(context: context)
        guard await service.open() else {
            throw AgentError(
                code: "hermes.history.state-unavailable",
                message: "Could not open Hermes state database",
                isRecoverable: true
            )
        }
        let hermesMessages = await service.fetchMessages(sessionId: sessionID, limit: fetchLimit)
        return mapHermesMessages(hermesMessages, sessionID: sessionID)
    }

    /// Map hydrated Hermes rows to agent messages (testable without I/O).
    public static func mapHermesMessages(_ messages: [HermesMessage], sessionID: String) -> [AgentMessage] {
        messages.compactMap { message in
            guard message.sessionId == sessionID || sessionID.isEmpty else { return nil }
            guard let role = agentRole(for: message.role) else { return nil }
            if message.isCompactionSummary, !message.containsCompactionSummary {
                return nil
            }
            let content = message.content
            guard !content.isEmpty else { return nil }
            return AgentMessage(
                id: deterministicAgentMessageID(sessionID: sessionID, hermesMessageID: message.id),
                role: role,
                content: content
            )
        }
    }

    public static func deterministicAgentMessageID(sessionID: String, hermesMessageID: Int) -> UUID {
        var hasher = SHA256()
        hasher.update(data: bytes(of: messageIDNamespace))
        hasher.update(data: Data(sessionID.utf8))
        hasher.update(data: [0x00])
        hasher.update(data: Data("\(hermesMessageID)".utf8))
        var digest = Array(hasher.finalize().prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x80
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private static func agentRole(for hermesRole: String) -> AgentMessageRole? {
        switch hermesRole {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "tool":
            return .tool
        case "system":
            return .system
        default:
            return nil
        }
    }

    private static func bytes(of uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}
