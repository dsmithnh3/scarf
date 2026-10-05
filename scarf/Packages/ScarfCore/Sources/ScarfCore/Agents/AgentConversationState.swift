import Foundation

/// Backend-neutral state derived from an `AgentEvent` stream.
///
/// The reducer deliberately contains no Hermes- or Claude-specific behavior so
/// a shared chat surface can consume either backend without duplicating event
/// lifecycle rules.
public struct AgentConversationState: Equatable, Sendable {
    public private(set) var session: AgentSession?
    public private(set) var messages: [AgentMessage] = []

    public private(set) var assistantDraft: String = ""
    public private(set) var reasoningDraft: String = ""
    public private(set) var reasoningBlocks: [String] = []

    public private(set) var toolCalls: [AgentToolCall] = []
    public private(set) var toolResults: [String: AgentToolResult] = [:]

    public private(set) var commands: [AgentCommand] = []
    public private(set) var commandOutput: [String: String] = [:]
    public private(set) var commandResults: [String: AgentCommandResult] = [:]

    public private(set) var fileChanges: [AgentFileChange] = []
    public private(set) var permissionRequest: AgentPermissionRequest?
    public private(set) var usage: AgentUsage?
    public private(set) var error: AgentError?
    public private(set) var stopReason: String?

    public private(set) var isRunning = false
    public private(set) var isClosed = false

    public init() {}

    /// Hydrate committed transcript fields after a session identity restore.
    ///
    /// Does not touch drafts, permissions, or lifecycle flags — those remain
    /// owned by the live event reducer / controller. When both calls/commands
    /// and their results are present, status is aligned by id the same way
    /// the live reducer does on completion events.
    public mutating func restoreDurableTranscript(
        messages: [AgentMessage],
        toolResults: [String: AgentToolResult] = [:],
        usage: AgentUsage? = nil,
        toolCalls: [AgentToolCall] = [],
        commands: [AgentCommand] = [],
        commandOutput: [String: String] = [:],
        commandResults: [String: AgentCommandResult] = [:],
        fileChanges: [AgentFileChange] = [],
        reasoningBlocks: [String] = []
    ) {
        self.messages = messages
        self.toolResults = toolResults
        self.usage = usage
        self.toolCalls = toolCalls
        self.commands = commands
        self.commandOutput = commandOutput
        self.commandResults = commandResults
        self.fileChanges = fileChanges
        self.reasoningBlocks = reasoningBlocks

        for (toolCallID, result) in toolResults {
            if let index = self.toolCalls.firstIndex(where: { $0.id == toolCallID }) {
                self.toolCalls[index].status = result.status
            }
        }
        for (commandID, result) in commandResults {
            if let index = self.commands.firstIndex(where: { $0.id == commandID }) {
                self.commands[index].status = result.exitCode == 0 ? .completed : .failed
            }
        }
    }

    public mutating func beginUserTurn(_ content: String) {
        messages.append(AgentMessage(role: .user, content: content))
        isRunning = true
        isClosed = false
        stopReason = nil
        error = nil
        permissionRequest = nil
    }

    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case .sessionStarted(let session):
            self.session = session
            isClosed = false

        case .textStarted:
            isRunning = true

        case .textDelta(let text):
            isRunning = true
            assistantDraft += text

        case .textCompleted:
            commitAssistantDraft()

        case .reasoningStarted:
            isRunning = true

        case .reasoningDelta(let text):
            isRunning = true
            reasoningDraft += text

        case .reasoningCompleted:
            commitReasoningDraft()

        case .toolStarted(let toolCall):
            upsertToolCall(toolCall)

        case .toolUpdated(let toolCall):
            upsertToolCall(toolCall)

        case .toolCompleted(let result):
            toolResults[result.toolCallID] = result
            if let index = toolCalls.firstIndex(where: { $0.id == result.toolCallID }) {
                toolCalls[index].status = result.status
            }

        case .commandStarted(let command):
            upsertCommand(command)

        case .commandOutput(let commandID, let text):
            commandOutput[commandID, default: ""] += text

        case .commandCompleted(let result):
            commandResults[result.commandID] = result
            if let index = commands.firstIndex(where: { $0.id == result.commandID }) {
                commands[index].status = result.exitCode == 0 ? .completed : .failed
            }

        case .fileChanged(let change):
            fileChanges.append(change)

        case .permissionRequested(let request):
            permissionRequest = request

        case .usageUpdated(let usage):
            self.usage = usage

        case .turnCompleted(let stopReason):
            commitReasoningDraft()
            commitAssistantDraft()
            self.stopReason = stopReason
            permissionRequest = nil
            isRunning = false

        case .sessionClosed:
            commitReasoningDraft()
            commitAssistantDraft()
            permissionRequest = nil
            isRunning = false
            isClosed = true

        case .error(let error):
            self.error = error
        }
    }

    private mutating func commitAssistantDraft() {
        guard !assistantDraft.isEmpty else { return }
        messages.append(AgentMessage(role: .assistant, content: assistantDraft))
        assistantDraft = ""
    }

    private mutating func commitReasoningDraft() {
        guard !reasoningDraft.isEmpty else { return }
        reasoningBlocks.append(reasoningDraft)
        reasoningDraft = ""
    }

    private mutating func upsertToolCall(_ toolCall: AgentToolCall) {
        if let index = toolCalls.firstIndex(where: { $0.id == toolCall.id }) {
            toolCalls[index] = toolCall
        } else {
            toolCalls.append(toolCall)
        }
    }

    private mutating func upsertCommand(_ command: AgentCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }
}
