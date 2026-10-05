import Foundation

/// Durable transcript snapshot for one Scarf conversation after a reload.
///
/// This is intentionally smaller than live `AgentConversationState`: only
/// committed messages, tool results, and usage are persisted. Drafts,
/// permissions, and in-flight tool/command state stay in the reducer.
public struct AgentConversationTranscript: Codable, Equatable, Sendable {
    public var conversationID: String
    public var messages: [AgentMessage]
    public var toolResults: [String: AgentToolResult]
    public var usage: AgentUsage?
    public var updatedAt: String?

    public init(
        conversationID: String,
        messages: [AgentMessage] = [],
        toolResults: [String: AgentToolResult] = [:],
        usage: AgentUsage? = nil,
        updatedAt: String? = nil
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.toolResults = toolResults
        self.usage = usage
        self.updatedAt = updatedAt
    }

    public init(conversationID: String, state: AgentConversationState, updatedAt: String? = nil) {
        self.conversationID = conversationID
        self.messages = state.messages
        self.toolResults = state.toolResults
        self.usage = state.usage
        self.updatedAt = updatedAt
    }
}

/// Persistence seam for durable conversation transcript. File-backed by
/// ``AgentConversationTranscriptStore``; tests inject a temp-directory URL as
/// the reload boundary.
public protocol AgentConversationTranscriptPersisting: Sendable {
    func save(_ transcript: AgentConversationTranscript) throws
    func load(conversationID: String) throws -> AgentConversationTranscript?
    func remove(conversationID: String) throws
}

/// JSON map of Scarf conversation id → durable transcript snapshot.
///
/// Callers choose the file URL. Production uses
/// ``productionFileURL(hermesHome:)`` (aligned with
/// `HermesPathSet.agentConversationTranscripts`); tests inject a temp
/// directory so a second store instance proves the reload boundary without
/// coupling this slice to GuardedJSONStore/transport.
public struct AgentConversationTranscriptStore: AgentConversationTranscriptPersisting, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Production sidecar under a Hermes home. Keep byte-identical to
    /// `HermesPathSet.agentConversationTranscripts`
    /// (`{home}/scarf/agent_conversation_transcripts.json`).
    public static func productionFileURL(hermesHome: String) -> URL {
        URL(fileURLWithPath: hermesHome + "/scarf/agent_conversation_transcripts.json")
    }

    /// Convenience for app/bootstrap wiring against a Hermes home directory.
    public init(hermesHome: String) {
        self.init(fileURL: Self.productionFileURL(hermesHome: hermesHome))
    }

    public func save(_ transcript: AgentConversationTranscript) throws {
        var envelope = try loadEnvelope()
        var stored = transcript
        if stored.updatedAt == nil {
            stored.updatedAt = ISO8601DateFormatter().string(from: Date())
        }
        envelope.transcripts[transcript.conversationID] = stored
        try writeEnvelope(envelope)
    }

    public func load(conversationID: String) throws -> AgentConversationTranscript? {
        try loadEnvelope().transcripts[conversationID]
    }

    public func remove(conversationID: String) throws {
        var envelope = try loadEnvelope()
        guard envelope.transcripts.removeValue(forKey: conversationID) != nil else { return }
        try writeEnvelope(envelope)
    }

    private struct Envelope: Codable {
        var transcripts: [String: AgentConversationTranscript]
    }

    private func loadEnvelope() throws -> Envelope {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return Envelope(transcripts: [:])
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return Envelope(transcripts: [:])
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
