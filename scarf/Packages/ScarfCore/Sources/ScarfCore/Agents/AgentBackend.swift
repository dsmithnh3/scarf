import Foundation

public enum AgentInstallationStatus: Equatable, Sendable {
    case available(version: String?)
    case notInstalled
    case unavailable(reason: String)
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
