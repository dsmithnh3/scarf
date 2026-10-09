import Foundation

/// Durable transcript snapshot for one Scarf conversation after a reload.
///
/// This is intentionally smaller than live `AgentConversationState`: only
/// committed messages, tool/command/file activity, reasoning blocks, and
/// usage are persisted. Drafts, permissions, and lifecycle flags stay in
/// the reducer.
public struct AgentConversationTranscript: Codable, Equatable, Sendable {
    public var conversationID: String
    public var messages: [AgentMessage]
    public var toolResults: [String: AgentToolResult]
    public var usage: AgentUsage?
    public var toolCalls: [AgentToolCall]
    public var commands: [AgentCommand]
    public var commandOutput: [String: String]
    public var commandResults: [String: AgentCommandResult]
    public var fileChanges: [AgentFileChange]
    public var reasoningBlocks: [String]
    public var updatedAt: String?

    public init(
        conversationID: String,
        messages: [AgentMessage] = [],
        toolResults: [String: AgentToolResult] = [:],
        usage: AgentUsage? = nil,
        toolCalls: [AgentToolCall] = [],
        commands: [AgentCommand] = [],
        commandOutput: [String: String] = [:],
        commandResults: [String: AgentCommandResult] = [:],
        fileChanges: [AgentFileChange] = [],
        reasoningBlocks: [String] = [],
        updatedAt: String? = nil
    ) {
        self.conversationID = conversationID
        self.messages = messages
        self.toolResults = toolResults
        self.usage = usage
        self.toolCalls = toolCalls
        self.commands = commands
        self.commandOutput = commandOutput
        self.commandResults = commandResults
        self.fileChanges = fileChanges
        self.reasoningBlocks = reasoningBlocks
        self.updatedAt = updatedAt
    }

    public init(conversationID: String, state: AgentConversationState, updatedAt: String? = nil) {
        self.conversationID = conversationID
        self.messages = state.messages
        self.toolResults = state.toolResults
        self.usage = state.usage
        self.toolCalls = state.toolCalls
        self.commands = state.commands
        self.commandOutput = state.commandOutput
        self.commandResults = state.commandResults
        self.fileChanges = state.fileChanges
        self.reasoningBlocks = state.reasoningBlocks
        self.updatedAt = updatedAt
    }

    /// True when any durable field has content worth writing.
    public var hasDurableContent: Bool {
        !messages.isEmpty
            || !toolResults.isEmpty
            || usage != nil
            || !toolCalls.isEmpty
            || !commands.isEmpty
            || !commandOutput.isEmpty
            || !commandResults.isEmpty
            || !fileChanges.isEmpty
            || !reasoningBlocks.isEmpty
    }

    /// Reconcile this Scarf-owned durable snapshot with optional backend-reported
    /// history messages.
    ///
    /// Contract:
    /// - Empty backend history → prefer Scarf unchanged (messages + activity).
    /// - Empty Scarf messages + non-empty backend → adopt backend messages;
    ///   keep Scarf activity fields.
    /// - Both non-empty:
    ///   1. Merge by `AgentMessage.id` (Scarf order/content wins on collision).
    ///   2. For remaining unmatched backend messages, match by role + exact
    ///      content against unmatched Scarf messages (greedy, Scarf order).
    ///      Matched pairs keep the Scarf message; unmatched backend messages
    ///      append after. Scarf activity is always retained.
    ///
    /// Role+content matching covers cross-source id schemes (Hermes state.db
    /// deterministic ids vs Scarf random UUIDs) without inventing a second
    /// conversation state system.
    public func reconciling(withBackendHistory backendMessages: [AgentMessage]) -> AgentConversationTranscript {
        if backendMessages.isEmpty {
            return self
        }

        if messages.isEmpty {
            var adopted = self
            adopted.messages = backendMessages
            return adopted
        }

        let scarfIDs = Set(messages.map(\.id))
        // Scarf turns already paired by id are not available for content match.
        var claimedScarfIndices = Set(
            messages.indices.filter { index in
                backendMessages.contains { $0.id == messages[index].id }
            }
        )

        var merged = messages
        for backend in backendMessages {
            if scarfIDs.contains(backend.id) {
                continue
            }
            if let matchIndex = messages.indices.first(where: { index in
                !claimedScarfIndices.contains(index)
                    && messages[index].role == backend.role
                    && messages[index].content == backend.content
            }) {
                claimedScarfIndices.insert(matchIndex)
                continue
            }
            merged.append(backend)
        }

        var result = self
        result.messages = merged
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case messages
        case toolResults
        case usage
        case toolCalls
        case commands
        case commandOutput
        case commandResults
        case fileChanges
        case reasoningBlocks
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        messages = try container.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
        toolResults = try container.decodeIfPresent([String: AgentToolResult].self, forKey: .toolResults) ?? [:]
        usage = try container.decodeIfPresent(AgentUsage.self, forKey: .usage)
        // Missing activity keys decode as empty so first-slice JSON still loads.
        toolCalls = try container.decodeIfPresent([AgentToolCall].self, forKey: .toolCalls) ?? []
        commands = try container.decodeIfPresent([AgentCommand].self, forKey: .commands) ?? []
        commandOutput = try container.decodeIfPresent([String: String].self, forKey: .commandOutput) ?? [:]
        commandResults = try container.decodeIfPresent(
            [String: AgentCommandResult].self,
            forKey: .commandResults
        ) ?? [:]
        fileChanges = try container.decodeIfPresent([AgentFileChange].self, forKey: .fileChanges) ?? []
        reasoningBlocks = try container.decodeIfPresent([String].self, forKey: .reasoningBlocks) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
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
/// directory so a second store instance proves the reload boundary.
///
/// One store owns this path: all RMW goes through ``GuardedSidecarStore`` /
/// ``GuardedJSONStore`` (inspect → mutate → publish). Damage policy is
/// ``GuardedDamagePolicy/refuseForever`` — durable messages/activity must
/// not be silently rebuilt from empty after corruption.
public struct AgentConversationTranscriptStore: AgentConversationTranscriptPersisting, GuardedSidecarStore, Sendable {
    public static let label = "agent_conversation_transcripts.json"
    public static let maxBytes = 4 * 1024 * 1024
    public static let damagePolicy = GuardedDamagePolicy.refuseForever

    public let fileURL: URL
    public nonisolated let transport: any ServerTransport

    public init(fileURL: URL, transport: any ServerTransport = LocalTransport()) {
        self.fileURL = fileURL
        self.transport = transport
    }

    /// Production sidecar under a Hermes home. Keep byte-identical to
    /// `HermesPathSet.agentConversationTranscripts`
    /// (`{home}/scarf/agent_conversation_transcripts.json`).
    public static func productionFileURL(hermesHome: String) -> URL {
        URL(fileURLWithPath: hermesHome + "/scarf/agent_conversation_transcripts.json")
    }

    /// Convenience for app/bootstrap wiring against a Hermes home directory.
    public init(hermesHome: String, transport: any ServerTransport = LocalTransport()) {
        self.init(fileURL: Self.productionFileURL(hermesHome: hermesHome), transport: transport)
    }

    public func save(_ transcript: AgentConversationTranscript) throws {
        try mutate { envelope in
            var stored = transcript
            if stored.updatedAt == nil {
                stored.updatedAt = ISO8601DateFormatter().string(from: Date())
            }
            envelope.transcripts[transcript.conversationID] = stored
            return true
        }
    }

    public func load(conversationID: String) throws -> AgentConversationTranscript? {
        try loadEnvelope().transcripts[conversationID]
    }

    public func remove(conversationID: String) throws {
        try mutate { envelope in
            guard envelope.transcripts.removeValue(forKey: conversationID) != nil else {
                return false
            }
            return true
        }
    }

    private struct Envelope: Codable {
        var transcripts: [String: AgentConversationTranscript]
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
        return (decoded ?? Envelope(transcripts: [:]), inspection)
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
