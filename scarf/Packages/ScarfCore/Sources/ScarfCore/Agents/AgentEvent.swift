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
    case permissionRequested(AgentPermissionRequest)
    case usageUpdated(AgentUsage)
    case sessionCompleted
    case error(AgentError)
}
