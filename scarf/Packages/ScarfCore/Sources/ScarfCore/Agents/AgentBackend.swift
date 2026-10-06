import Foundation

public enum AgentInstallationStatus: Equatable, Sendable {
    case available(version: String?)
    case notInstalled
    case unavailable(reason: String)
}

/// Event emitted by a backend with the session that produced it.
///
/// AgentEvent intentionally remains backend/session neutral. This envelope is
/// the transport-level routing context required when one backend owns multiple
/// simultaneous sessions (for example, two Claude Code chat windows).
public struct AgentBackendEvent: Equatable, Sendable {
    public let sessionID: String
    public let event: AgentEvent

    public init(sessionID: String, event: AgentEvent) {
        self.sessionID = sessionID
        self.event = event
    }
}

public protocol AgentBackend: Sendable {
    var id: AgentID { get }
    var displayName: String { get }
    var capabilities: AgentCapabilities { get }
    var events: AsyncStream<AgentEvent> { get }

    func installationStatus() async -> AgentInstallationStatus

    /// Resolved CLI executable path when discoverable. `nil` means not found —
    /// never a guessed fallback path.
    func resolvedExecutablePath() -> String?

    /// Credential/auth health from a verified probe only.
    ///
    /// Default is ``AgentAuthHealth/notProbed``. Concrete backends override
    /// when a real file/env/protocol check exists (Hermes today). Do not invent
    /// OAuth UI or Claude credential parsers here. Model discovery stays
    /// separate and remains blocked until a verified path exists.
    func authHealth() async -> AgentAuthHealth

    func models() async throws -> [AgentModel]
    func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession
    func resumeSession(_ session: AgentSession) async throws -> AgentSession
    func send(_ message: AgentMessage, in session: AgentSession) async throws
    func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws
    func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws
    func cancel(session: AgentSession) async
    func close(session: AgentSession) async

    /// Structured conversation history for a resumed session, when the backend
    /// can provide it as `[AgentMessage]`.
    ///
    /// Backends without a verified structured history source must return `[]`
    /// rather than inventing parsers or advertising a capability they do not
    /// have. Empty history keeps Scarf's durable transcript preferred via
    /// ``AgentConversationTranscript/reconciling(withBackendHistory:)``.
    func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage]
}

extension AgentBackend {
    /// Default: no discoverable executable path.
    public func resolvedExecutablePath() -> String? { nil }

    /// Default: no verified auth probe (stay silent in diagnostics).
    public func authHealth() async -> AgentAuthHealth { .notProbed }

    /// Default: no structured history. Concrete backends override when a real
    /// protocol source exists.
    public func fetchConversationHistory(for session: AgentSession) async throws -> [AgentMessage] {
        []
    }
}

/// Opt-in session-aware event source for backends that can own more than one
/// live session at a time.
///
/// `AgentBackend.events` remains available for compatibility. The coordinator
/// prefers this scoped stream whenever a backend conforms, preventing events
/// from one session from mutating another conversation's state.
public protocol SessionScopedAgentBackend: AgentBackend {
    var sessionEvents: AsyncStream<AgentBackendEvent> { get }
}
