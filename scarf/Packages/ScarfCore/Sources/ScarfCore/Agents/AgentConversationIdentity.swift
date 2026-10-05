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
/// Callers choose the file URL. Production uses
/// ``productionFileURL(hermesHome:)`` (aligned with
/// `HermesPathSet.agentConversationIdentities`); tests inject a temp
/// directory so a second store instance proves the reload boundary.
///
/// One store owns this path: all RMW goes through ``GuardedSidecarStore`` /
/// ``GuardedJSONStore`` (inspect → mutate → publish). Damage policy is
/// ``GuardedDamagePolicy/refuseForever`` — identity rows are needed for
/// resume and must not be silently rebuilt from empty after corruption.
public struct AgentConversationIdentityStore: AgentConversationIdentityPersisting, GuardedSidecarStore, Sendable {
    public static let label = "agent_conversation_identities.json"
    public static let maxBytes = 1 * 1024 * 1024
    public static let damagePolicy = GuardedDamagePolicy.refuseForever

    public let fileURL: URL
    public nonisolated let transport: any ServerTransport

    public init(fileURL: URL, transport: any ServerTransport = LocalTransport()) {
        self.fileURL = fileURL
        self.transport = transport
    }

    /// Production sidecar under a Hermes home. Keep byte-identical to
    /// `HermesPathSet.agentConversationIdentities` (`{home}/scarf/agent_conversation_identities.json`).
    public static func productionFileURL(hermesHome: String) -> URL {
        URL(fileURLWithPath: hermesHome + "/scarf/agent_conversation_identities.json")
    }

    /// Convenience for app/bootstrap wiring against a Hermes home directory.
    public init(hermesHome: String, transport: any ServerTransport = LocalTransport()) {
        self.init(fileURL: Self.productionFileURL(hermesHome: hermesHome), transport: transport)
    }

    public func save(_ identity: AgentConversationIdentity) throws {
        try mutate { envelope in
            var stored = identity
            if stored.updatedAt == nil {
                stored.updatedAt = ISO8601DateFormatter().string(from: Date())
            }
            envelope.identities[identity.conversationID] = stored
            return true
        }
    }

    public func load(conversationID: String) throws -> AgentConversationIdentity? {
        try loadEnvelope().identities[conversationID]
    }

    public func remove(conversationID: String) throws {
        try mutate { envelope in
            guard envelope.identities.removeValue(forKey: conversationID) != nil else {
                return false
            }
            return true
        }
    }

    private struct Envelope: Codable {
        var identities: [String: AgentConversationIdentity]
    }

    private func loadEnvelope() throws -> Envelope {
        try inspectEnvelope().envelope
    }

    private func inspectEnvelope() throws -> (envelope: Envelope, inspection: GuardedJSONStore.Inspection) {
        let path = fileURL.path
        let (inspection, decoded) = inspectDecoding(Envelope.self, at: path)
        if case .unreadable = inspection.state {
            throw GuardedStoreError.refusedUnreadableOverwrite(path: path, label: Self.label)
        }
        return (decoded ?? Envelope(identities: [:]), inspection)
    }

    /// Single RMW chokepoint: the write validates against the same inspection
    /// the in-memory envelope was built from.
    private func mutate(_ body: (inout Envelope) throws -> Bool) throws {
        let path = fileURL.path
        var (envelope, inspection) = try inspectEnvelope()
        let changed = try body(&envelope)
        guard changed else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try publish(data, to: path, after: inspection)
    }
}
