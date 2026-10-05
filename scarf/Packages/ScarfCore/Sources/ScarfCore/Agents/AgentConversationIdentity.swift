import Foundation

/// Backend-neutral identity for one Scarf conversation after a reload.
///
/// This is intentionally smaller than `AgentConversationState`: live
/// transcript/tool/permission state stays in the reducer. Persistence only
/// records enough to know which backend session to resume.
public struct AgentConversationIdentity: Codable, Equatable, Sendable {
    public var conversationID: String
    public var backendID: AgentID
    public var sessionID: String
    public var workingDirectoryPath: String?
    public var updatedAt: String?

    public init(
        conversationID: String,
        backendID: AgentID,
        sessionID: String,
        workingDirectoryPath: String? = nil,
        updatedAt: String? = nil
    ) {
        self.conversationID = conversationID
        self.backendID = backendID
        self.sessionID = sessionID
        self.workingDirectoryPath = workingDirectoryPath
        self.updatedAt = updatedAt
    }

    public init(conversationID: String, session: AgentSession, updatedAt: String? = nil) {
        self.conversationID = conversationID
        self.backendID = session.backendID
        self.sessionID = session.id
        self.workingDirectoryPath = session.workingDirectory?.path
        self.updatedAt = updatedAt
    }

    public func makeSession() -> AgentSession {
        AgentSession(
            id: sessionID,
            backendID: backendID,
            workingDirectory: workingDirectoryPath.map { URL(fileURLWithPath: $0) }
        )
    }
}

/// Persistence seam for conversation identity. File-backed by
/// ``AgentConversationIdentityStore``; tests inject a temp-directory URL as
/// the reload boundary.
public protocol AgentConversationIdentityPersisting: Sendable {
    func save(_ identity: AgentConversationIdentity) throws
    func load(conversationID: String) throws -> AgentConversationIdentity?
    func remove(conversationID: String) throws
}

/// JSON map of Scarf conversation id → backend/session identity.
///
/// Callers choose the file URL. Production can point at
/// `~/.hermes/scarf/agent_conversation_identities.json`; tests use a temp
/// directory so a second store instance proves the reload boundary without
/// coupling this slice to GuardedJSONStore/transport.
public struct AgentConversationIdentityStore: AgentConversationIdentityPersisting, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func save(_ identity: AgentConversationIdentity) throws {
        var envelope = try loadEnvelope()
        var stored = identity
        if stored.updatedAt == nil {
            stored.updatedAt = ISO8601DateFormatter().string(from: Date())
        }
        envelope.identities[identity.conversationID] = stored
        try writeEnvelope(envelope)
    }

    public func load(conversationID: String) throws -> AgentConversationIdentity? {
        try loadEnvelope().identities[conversationID]
    }

    public func remove(conversationID: String) throws {
        var envelope = try loadEnvelope()
        guard envelope.identities.removeValue(forKey: conversationID) != nil else { return }
        try writeEnvelope(envelope)
    }

    private struct Envelope: Codable {
        var identities: [String: AgentConversationIdentity]
    }

    private func loadEnvelope() throws -> Envelope {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return Envelope(identities: [:])
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return Envelope(identities: [:])
        }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private func writeEnvelope(_ envelope: Envelope) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
