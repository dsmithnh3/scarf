import Foundation
import ScarfCore

enum HermesEventMapper {
    nonisolated static func map(_ event: ACPEvent) -> [AgentEvent] {
        switch event {
        case .messageChunk(_, let text, _, _, _):
            return [.textDelta(text)]

        case .thoughtChunk(_, let text, _):
            return [.reasoningDelta(text)]

        case .toolCallStart(_, let call):
            return [.toolStarted(AgentToolCall(
                id: call.toolCallId,
                title: call.title,
                kind: call.kind,
                status: toolStatus(call.status),
                input: call.rawInput.flatMap(jsonString)
            ))]

        case .toolCallUpdate(_, let update):
            let status = toolStatus(update.status)
            if [.completed, .failed, .cancelled].contains(status) {
                let output = update.rawOutput ?? (update.content.isEmpty ? nil : update.content)
                return [.toolCompleted(AgentToolResult(
                    toolCallID: update.toolCallId,
                    status: status,
                    output: output,
                    errorMessage: status == .failed ? output : nil
                ))]
            }
            return [.toolUpdated(AgentToolCall(
                id: update.toolCallId,
                title: "",
                kind: update.kind,
                status: status,
                input: update.argumentsJSON
            ))]

        case .permissionRequest(_, let requestId, let request):
            let options = request.options.map {
                AgentPermissionOption(id: $0.optionId, title: $0.name)
            }
            return [.permissionRequested(AgentPermissionRequest(
                id: String(requestId),
                title: request.toolCallTitle,
                detail: request.toolCallKind,
                options: options
            ))]

        case .promptComplete(_, let response):
            let usage = AgentUsage(
                inputTokens: response.inputTokens,
                outputTokens: response.outputTokens,
                reasoningTokens: response.thoughtTokens,
                cachedReadTokens: response.cachedReadTokens
            )
            return [.usageUpdated(usage), .turnCompleted(stopReason: response.stopReason)]

        case .connectionLost(let reason):
            return [.error(AgentError(
                code: "hermes.connection-lost",
                message: reason,
                isRecoverable: true
            ))]

        case .availableCommands(_, let commands):
            return [
                .availableCommandsUpdated(
                    AgentSlashCommandACPDiscovery.descriptors(fromACPCommands: commands)
                )
            ]

        case .userMessageChunk,
             .sessionInfoUpdate,
             .unknown:
            return []
        }
    }

    nonisolated static func toolStatus(_ status: String) -> AgentToolStatus {
        switch status.lowercased() {
        case "pending", "queued":
            return .pending
        case "completed", "complete", "success", "succeeded":
            return .completed
        case "failed", "failure", "error":
            return .failed
        case "cancelled", "canceled":
            return .cancelled
        case "in_progress", "running", "started":
            return .running
        default:
            // Unknown additive statuses remain visible as active work rather
            // than being incorrectly reported as terminal success/failure.
            return .running
        }
    }

    nonisolated private static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
