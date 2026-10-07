import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent plan callout presenter")
struct AgentPlanCalloutPresenterTests {
    @Test("reads ExitPlanMode plan from tool input JSON")
    func readsPlanFromToolInput() {
        let tools = [
            AgentToolCall(id: "t1", title: "Bash", kind: "Bash", status: .running, input: #"{"command":"ls"}"#),
            AgentToolCall(
                id: "t2",
                title: "ExitPlanMode",
                kind: "ExitPlanMode",
                status: .completed,
                input: #"{"plan":"Ship the decoder"}"#
            ),
        ]
        #expect(AgentPlanCalloutPresenter.planText(from: tools) == "Ship the decoder")
    }

    @Test("missing or empty plan returns nil")
    func missingPlanReturnsNil() {
        #expect(AgentPlanCalloutPresenter.planText(from: [
            AgentToolCall(id: "t", title: "ExitPlanMode", kind: "ExitPlanMode", status: .running, input: "{}")
        ]) == nil)
        #expect(AgentPlanCalloutPresenter.planText(from: []) == nil)
    }
}
