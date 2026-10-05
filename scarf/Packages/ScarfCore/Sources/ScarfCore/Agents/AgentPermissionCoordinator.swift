import Foundation

/// Lifecycle status for one backend-neutral permission request.
public enum AgentPermissionStatus: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case answered
    case cancelled
}

/// How long an approval should apply when the backend supports scopes.
///
/// Hermes ACP today typically offers once/deny option ids; richer scopes are
/// reserved for backends that advertise them. Prefer `.unspecified` when the
/// wire payload does not say.
public enum AgentPermissionScope: String, Codable, Equatable, Hashable, Sendable {
    case once
    case session
    case always
    case unspecified
}

/// Backend-neutral permission request with enough identity for coordination.
///
/// Distinct from transcript rendering and from Hermes Rich Chat's
/// `PendingPermission` UI queue — this is the ScarfCore state-machine record.
/// Convert to `AgentPermissionRequest` for existing `AgentBackend.respond` /
/// `cancelPermission` calls (Hermes numeric ids preserved as strings).
public struct AgentPermissionRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var backendID: AgentID
    public var sessionID: String
    /// Action / tool category (Hermes `toolCallKind`, Claude `can_use_tool`, …).
    public var category: String
    /// Human-readable description (Hermes tool title / command summary).
    public var description: String
    /// Structured backend details (toolCallId, command, inputJSON, …).
    public var details: [String: String]
    public var options: [AgentPermissionOption]
    public var scope: AgentPermissionScope
    public var status: AgentPermissionStatus
    public var selectedOptionID: String?

    public init(
        id: String,
        backendID: AgentID,
        sessionID: String,
        category: String,
        description: String,
        details: [String: String] = [:],
        options: [AgentPermissionOption] = [],
        scope: AgentPermissionScope = .unspecified,
        status: AgentPermissionStatus = .pending,
        selectedOptionID: String? = nil
    ) {
        self.id = id
        self.backendID = backendID
        self.sessionID = sessionID
        self.category = category
        self.description = description
        self.details = details
        self.options = options
        self.scope = scope
        self.status = status
        self.selectedOptionID = selectedOptionID
    }

    /// Map the existing Hermes multi-agent permission event shape into a record.
    ///
    /// `AgentPermissionRequest.id` stays the ACP numeric request id as a string
    /// so `HermesBackend.respond` / `cancelPermission` keep working unchanged.
    public static func hermes(
        from request: AgentPermissionRequest,
        sessionID: String,
        toolCallID: String = "",
        scope: AgentPermissionScope = .once
    ) -> AgentPermissionRecord {
        var details: [String: String] = [:]
        if !toolCallID.isEmpty {
            details["toolCallId"] = toolCallID
        }
        return AgentPermissionRecord(
            id: request.id,
            backendID: .hermes,
            sessionID: sessionID,
            category: request.detail ?? "",
            description: request.title,
            details: details,
            options: request.options,
            scope: scope,
            status: .pending
        )
    }

    /// Build a coordinator record from a live `permissionRequested` event.
    ///
    /// Hermes keeps the ACP numeric-id adapter; other backends store a generic
    /// pending row without advertising capabilities they do not implement.
    public static func forEvent(
        _ request: AgentPermissionRequest,
        session: AgentSession
    ) -> AgentPermissionRecord {
        if session.backendID == .hermes {
            return .hermes(from: request, sessionID: session.id)
        }
        return AgentPermissionRecord(
            id: request.id,
            backendID: session.backendID,
            sessionID: session.id,
            category: request.detail ?? "",
            description: request.title,
            options: request.options,
            scope: .unspecified,
            status: .pending
        )
    }

    /// Wire shape expected by `AgentBackend.respond` / `cancelPermission`.
    public var asAgentPermissionRequest: AgentPermissionRequest {
        AgentPermissionRequest(
            id: id,
            title: description,
            detail: category.isEmpty ? nil : category,
            options: options
        )
    }
}

/// Generic permission queue / state machine for multi-agent conversations.
///
/// Mirrors Rich Chat queue rules (FIFO pending, id-keyed resolution, duplicate
/// id refresh) without transplanting CLUI UI. Does **not** enable Claude
/// `.permissions` — callers must keep capability advertisement truthful and
/// route answers through backends that implement the round trip.
public struct AgentPermissionCoordinator: Equatable, Sendable {
    public private(set) var records: [AgentPermissionRecord]

    public init(records: [AgentPermissionRecord] = []) {
        self.records = records
    }

    public var pending: [AgentPermissionRecord] {
        records.filter { $0.status == .pending }
    }

    /// Head of the pending queue — what a UI would present first.
    public var presented: AgentPermissionRecord? {
        pending.first
    }

    public static func supportsPermissions(_ capabilities: AgentCapabilities) -> Bool {
        capabilities.contains(.permissions)
    }

    /// Enqueue or refresh a pending request. Duplicate pending ids update in
    /// place (Hermes may re-send the same ACP request id).
    public mutating func record(_ request: AgentPermissionRecord) {
        var incoming = request
        incoming.status = .pending
        incoming.selectedOptionID = nil

        if let index = records.firstIndex(where: { $0.id == incoming.id && $0.status == .pending }) {
            records[index] = incoming
            return
        }
        records.append(incoming)
    }

    /// Answer a pending request by id. Unknown ids, non-pending rows, and
    /// option ids not in `options` are no-ops (return false).
    @discardableResult
    public mutating func answer(id: String, optionID: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id && $0.status == .pending }) else {
            return false
        }
        guard records[index].options.contains(where: { $0.id == optionID }) else {
            return false
        }
        records[index].status = .answered
        records[index].selectedOptionID = optionID
        return true
    }

    /// Cancel a pending request by id. Already-answered/cancelled ids are no-ops.
    @discardableResult
    public mutating func cancel(id: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id && $0.status == .pending }) else {
            return false
        }
        records[index].status = .cancelled
        records[index].selectedOptionID = nil
        return true
    }

    /// Drop pending rows (e.g. session close / turn end) while keeping history.
    public mutating func clearPending() {
        records.removeAll { $0.status == .pending }
    }
}
