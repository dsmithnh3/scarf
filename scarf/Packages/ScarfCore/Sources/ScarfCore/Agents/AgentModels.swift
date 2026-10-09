import Foundation

public struct AgentModel: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Split a catalog picker id (`provider:model…`) for ACP `session/set_model`.
///
/// Catalog rows use ``HermesModelInfo/id`` shape `providerID + ":" + modelID`.
/// The model half may contain `/` or additional `:` characters — only the
/// **first** colon separates provider from model. Passing the full picker id
/// as `modelID` into ``ACPClient/encodeModelChoice(modelID:providerID:)``
/// would double-prefix the provider.
public enum AgentModelPickerID {
    public static func split(_ pickerID: String) -> (providerID: String?, modelID: String) {
        let trimmed = pickerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else {
            return (nil, trimmed)
        }
        let provider = String(trimmed[..<colon])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.isEmpty {
            return (nil, model)
        }
        return (provider, model)
    }
}

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let backendID: AgentID
    public var workingDirectory: URL?
    public var metadata: [String: String]

    public init(
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

public struct AgentSessionConfiguration: Codable, Equatable, Sendable {
    public var workingDirectory: URL?
    public var modelID: String?
    public var metadata: [String: String]

    public init(
        workingDirectory: URL? = nil,
        modelID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.workingDirectory = workingDirectory
        self.modelID = modelID
        self.metadata = metadata
    }
}

public enum AgentMessageRole: String, Codable, Equatable, Hashable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct AgentMessage: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var role: AgentMessageRole
    public var content: String

    public init(id: UUID = UUID(), role: AgentMessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public enum AgentToolStatus: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public struct AgentToolCall: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var kind: String
    public var status: AgentToolStatus
    public var input: String?

    public init(
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

public struct AgentToolResult: Codable, Equatable, Hashable, Sendable {
    public let toolCallID: String
    public var status: AgentToolStatus
    public var output: String?
    public var errorMessage: String?

    public init(
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

public struct AgentPermissionOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct AgentPermissionRequest: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var detail: String?
    public var options: [AgentPermissionOption]

    public init(
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

public enum AgentCommandStatus: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public struct AgentCommand: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var command: String
    public var status: AgentCommandStatus

    public init(id: String, command: String, status: AgentCommandStatus) {
        self.id = id
        self.command = command
        self.status = status
    }
}

public struct AgentCommandResult: Codable, Equatable, Hashable, Sendable {
    public let commandID: String
    public var exitCode: Int32?
    public var output: String?
    public var errorOutput: String?

    public init(
        commandID: String,
        exitCode: Int32? = nil,
        output: String? = nil,
        errorOutput: String? = nil
    ) {
        self.commandID = commandID
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
    }
}

public enum AgentFileChangeKind: String, Codable, Equatable, Hashable, Sendable {
    case created
    case modified
    case deleted
    case renamed
    case unknown
}

public struct AgentFileChange: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var kind: AgentFileChangeKind
    public var diff: String?

    public init(path: String, kind: AgentFileChangeKind, diff: String? = nil) {
        self.path = path
        self.kind = kind
        self.diff = diff
    }
}

public struct AgentUsage: Codable, Equatable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cachedReadTokens: Int

    public init(
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

public struct AgentError: Codable, Equatable, Hashable, Sendable, Error, CustomStringConvertible {
    public var code: String
    public var message: String
    public var isRecoverable: Bool

    public init(code: String, message: String, isRecoverable: Bool = false) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }

    /// Prefer the human message in UI and logs; keep `code` for diagnostics.
    public var description: String { message }
}
