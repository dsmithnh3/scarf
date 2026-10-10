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
    /// Default is ``AgentAuthHealth/notProbed``. Hermes probes its credential
    /// files. Claude Code probes `claude auth status`. Do not invent OAuth UI
    /// or parse Keychain / credential files here.
    func authHealth() async -> AgentAuthHealth

    func models() async throws -> [AgentModel]

    /// Live extension rows discovered after backend handshake (for example
    /// Claude control `initialize` agents). Default is empty — do not invent
    /// skills or plugins when the backend has no verified source.
    func discoveredExtensions() async -> [AgentExtensionDescriptor]

    func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession
    func resumeSession(_ session: AgentSession) async throws -> AgentSession
    func send(_ message: AgentMessage, in session: AgentSession) async throws
    /// Send a user message with optional ACP image blocks and Live Voice
    /// context notes. Default rejects non-empty images/notes (never silent drop).
    func send(
        _ message: AgentMessage,
        images: [ChatImageAttachment],
        contextNotes: [ACPContextNote],
        in session: AgentSession
    ) async throws
    func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws
    func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws
    func cancel(session: AgentSession) async
    func close(session: AgentSession) async

    /// Change the model on a live session when the backend supports it.
    ///
    /// Hermes implements this via ACP `session/set_model`. Claude Code does
    /// **not** — multi-agent Claude restarts with `--model` instead. Default
    /// throws unsupported (never a silent no-op).
    func setSessionModel(
        session: AgentSession,
        modelID: String,
        providerID: String?
    ) async throws

    /// Change the edit-approval mode on a live session when the backend supports it.
    ///
    /// Hermes implements this via ACP `session/set_mode` (v0.15+). Claude Code
    /// does **not**. Default throws unsupported (never a silent no-op).
    func setSessionMode(
        session: AgentSession,
        modeID: String
    ) async throws

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

    /// Default: no live extension discovery.
    public func discoveredExtensions() async -> [AgentExtensionDescriptor] { [] }

    /// Default: text-only. Non-empty images or context notes throw — never
    /// silently dropped. Concrete backends that support ACP multimodal /
    /// Live Voice notes override this.
    public func send(
        _ message: AgentMessage,
        images: [ChatImageAttachment],
        contextNotes: [ACPContextNote],
        in session: AgentSession
    ) async throws {
        if !images.isEmpty {
            throw AgentError(
                code: "agent.images-unsupported",
                message: "\(displayName) does not support image attachments",
                isRecoverable: true
            )
        }
        if !contextNotes.isEmpty {
            throw AgentError(
                code: "agent.context-notes-unsupported",
                message: "\(displayName) does not support Live Voice context notes",
                isRecoverable: true
            )
        }
        try await send(message, in: session)
    }

    /// Default: mid-session model changes are unsupported.
    public func setSessionModel(
        session: AgentSession,
        modelID: String,
        providerID: String?
    ) async throws {
        throw AgentError(
            code: "agent.set-session-model-unsupported",
            message: "\(displayName) does not support mid-session model changes",
            isRecoverable: true
        )
    }

    /// Default: mid-session approval-mode changes are unsupported.
    public func setSessionMode(
        session: AgentSession,
        modeID: String
    ) async throws {
        throw AgentError(
            code: "agent.set-session-mode-unsupported",
            message: "\(displayName) does not support session approval modes",
            isRecoverable: true
        )
    }

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
