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
    func models() async throws -> [AgentModel]
    func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession
    func resumeSession(_ session: AgentSession) async throws -> AgentSession
    func send(_ message: AgentMessage, in session: AgentSession) async throws
    func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws
    func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws
    func cancel(session: AgentSession) async
    func close(session: AgentSession) async
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
