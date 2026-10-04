import Foundation

struct AgentModel: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    var displayName: String

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

struct AgentSession: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let backendID: AgentID
    var workingDirectory: URL?
    var metadata: [String: String]

    init(
        id: String,
        backendID: AgentID,
        workingDirectory: URL? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.backendID = backendID
        self.workingDirectory = workingDirectory
        self.metadata = metadata
    }
}

struct AgentSessionConfiguration: Codable, Equatable, Sendable {
    var workingDirectory: URL?
    var modelID: String?
    var metadata: [String: String]

    init(
        workingDirectory: URL? = nil,
        modelID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.modelID = modelID
        self.metadata = metadata
    }
}

enum AgentMessageRole: String, Codable, Equatable, Hashable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct AgentMessage: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    var role: AgentMessageRole
    var content: String

    init(id: UUID = UUID(), role: AgentMessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

enum AgentToolStatus: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

struct AgentToolCall: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var kind: String
    var status: AgentToolStatus
    var input: String?

    init(
        id: String,
        title: String,
        kind: String,
        status: AgentToolStatus,
        input: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.input = input
    }
}

struct AgentToolResult: Codable, Equatable, Hashable, Sendable {
    let toolCallID: String
    var status: AgentToolStatus
    var output: String?
    var errorMessage: String?

    init(
        toolCallID: String,
        status: AgentToolStatus,
        output: String? = nil,
        errorMessage: String? = nil
    ) {
        self.toolCallID = toolCallID
        self.status = status
        self.output = output
        self.errorMessage = errorMessage
    }
}

struct AgentPermissionOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

struct AgentPermissionRequest: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var detail: String?
    var options: [AgentPermissionOption]

    init(
        id: String,
        title: String,
        detail: String? = nil,
        options: [AgentPermissionOption] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
    }
}

struct AgentUsage: Codable, Equatable, Hashable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var cachedReadTokens: Int

    init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        cachedReadTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedReadTokens = cachedReadTokens
    }
}

struct AgentError: Codable, Equatable, Hashable, Sendable, Error {
    var code: String
    var message: String
    var isRecoverable: Bool

    init(code: String, message: String, isRecoverable: Bool = false) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}
