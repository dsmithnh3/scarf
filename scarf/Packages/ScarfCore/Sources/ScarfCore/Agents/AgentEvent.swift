import Foundation

public enum AgentEvent: Equatable, Sendable {
    case sessionStarted(AgentSession)
    case textStarted
    case textDelta(String)
    case textCompleted
    case reasoningStarted
    case reasoningDelta(String)
    case reasoningCompleted
    case toolStarted(AgentToolCall)
    case toolUpdated(AgentToolCall)
    case toolCompleted(AgentToolResult)
    case commandStarted(AgentCommand)
    case commandOutput(commandID: String, text: String)
    case commandCompleted(AgentCommandResult)
    case fileChanged(AgentFileChange)
    case permissionRequested(AgentPermissionRequest)
    case usageUpdated(AgentUsage)
    case turnCompleted(stopReason: String?)
    case sessionClosed
    case error(AgentError)
}
