import Foundation

/// Extracts Claude `ExitPlanMode` plan text for a ScarfDesign callout.
///
/// No new ``AgentEvent`` — the decoder already stores the plan on the tool
/// call's `input` JSON. Returns the first non-empty `plan` string.
public enum AgentPlanCalloutPresenter {
    public static func planText(from toolCalls: [AgentToolCall]) -> String? {
        for tool in toolCalls where tool.kind.caseInsensitiveCompare("ExitPlanMode") == .orderedSame {
            guard let plan = planString(in: tool.input), !plan.isEmpty else { continue }
            return plan
        }
        return nil
    }

    public static func planText(from state: AgentConversationState) -> String? {
        planText(from: state.toolCalls)
    }

    private static func planString(in inputJSON: String?) -> String? {
        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = object["plan"] as? String
        else { return nil }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
