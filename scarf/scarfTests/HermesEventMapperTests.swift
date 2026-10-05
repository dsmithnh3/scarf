import Testing
import ScarfCore
@testable import scarf

@Suite("Hermes agent event mapping")
struct HermesEventMapperTests {

    @Test("assistant and thought chunks map to generic deltas")
    func textAndReasoning() {
        #expect(HermesEventMapper.map(.messageChunk(sessionId: "s", text: "hello")) == [.textDelta("hello")])
        #expect(HermesEventMapper.map(.thoughtChunk(sessionId: "s", text: "thinking")) == [.reasoningDelta("thinking")])
    }

    @Test("tool start preserves identity and visible metadata")
    func toolStart() {
        let call = ACPToolCallEvent(
            toolCallId: "call-1",
            title: "read_file: config.yaml",
            kind: "read",
            status: "in_progress",
            content: "",
            rawInput: nil,
            locationPaths: ["/tmp/config.yaml"]
        )

        let expected = AgentToolCall(
            id: "call-1",
            title: "read_file: config.yaml",
            kind: "read",
            status: .running,
            input: nil
        )
        #expect(HermesEventMapper.map(.toolCallStart(sessionId: "s", call: call)) == [.toolStarted(expected)])
    }

    @Test("tool completion maps output and terminal state")
    func toolCompletion() {
        let update = ACPToolCallUpdateEvent(
            toolCallId: "call-1",
            kind: "read",
            status: "completed",
            content: "fallback",
            rawOutput: "file contents"
        )

        let expected = AgentToolResult(
            toolCallID: "call-1",
            status: .completed,
            output: "file contents"
        )
        #expect(HermesEventMapper.map(.toolCallUpdate(sessionId: "s", update: update)) == [.toolCompleted(expected)])
    }

    @Test("permission request becomes backend-neutral permission model")
    func permissionRequest() {
        let request = ACPPermissionRequestEvent(
            toolCallTitle: "Run command",
            toolCallKind: "terminal",
            options: [(optionId: "allow_once", name: "Allow once"), (optionId: "deny", name: "Deny")],
            toolCallId: "perm-1"
        )

        let events = HermesEventMapper.map(.permissionRequest(sessionId: "s", requestId: 42, request: request))
        let expected = AgentPermissionRequest(
            id: "42",
            title: "Run command",
            detail: "terminal",
            options: [
                AgentPermissionOption(id: "allow_once", title: "Allow once"),
                AgentPermissionOption(id: "deny", title: "Deny")
            ]
        )
        #expect(events == [.permissionRequested(expected)])
    }

    @Test("prompt completion emits usage then turn completion")
    func promptCompletion() {
        let result = ACPPromptResult(
            stopReason: "end_turn",
            inputTokens: 10,
            outputTokens: 20,
            thoughtTokens: 3,
            cachedReadTokens: 4
        )
        let usage = AgentUsage(inputTokens: 10, outputTokens: 20, reasoningTokens: 3, cachedReadTokens: 4)

        #expect(HermesEventMapper.map(.promptComplete(sessionId: "s", response: result)) == [
            .usageUpdated(usage),
            .turnCompleted(stopReason: "end_turn")
        ])
    }

    @Test("connection loss maps to recoverable generic error")
    func connectionLoss() {
        #expect(HermesEventMapper.map(.connectionLost(reason: "ssh disconnected")) == [
            .error(AgentError(code: "hermes.connection-lost", message: "ssh disconnected", isRecoverable: true))
        ])
    }

    @Test("available_commands_update maps into AgentEvent slash descriptors")
    func availableCommandsMapToAgentEvent() {
        let mapped = HermesEventMapper.map(.availableCommands(sessionId: "s", commands: [
            ["name": "/help", "description": "List available commands"],
            ["name": "steer", "description": "Inject guidance", "input": ["hint": "<guidance>"]],
        ]))

        #expect(mapped.count == 1)
        guard let first = mapped.first,
              case .availableCommandsUpdated(let commands) = first else {
            Issue.record("expected availableCommandsUpdated")
            return
        }
        #expect(commands.map(\.name) == ["help", "steer"])
        #expect(commands[1].argumentHint == "<guidance>")
        #expect(commands.allSatisfy { $0.source == .hermes })
    }

    @Test("non-shared Hermes events remain backend-specific and are ignored by generic mapper")
    func ignoresBackendSpecificEvents() {
        #expect(HermesEventMapper.map(.userMessageChunk(sessionId: "s", text: "history")) == [])
        #expect(HermesEventMapper.map(.availableCommands(sessionId: "s", commands: [])) == [
            .availableCommandsUpdated([])
        ])
        #expect(HermesEventMapper.map(.unknown(sessionId: "s", type: "future")) == [])
    }

    @Test("Hermes status vocabulary maps defensively")
    func toolStatuses() {
        #expect(HermesEventMapper.toolStatus("pending") == .pending)
        #expect(HermesEventMapper.toolStatus("in_progress") == .running)
        #expect(HermesEventMapper.toolStatus("completed") == .completed)
        #expect(HermesEventMapper.toolStatus("success") == .completed)
        #expect(HermesEventMapper.toolStatus("error") == .failed)
        #expect(HermesEventMapper.toolStatus("cancelled") == .cancelled)
        #expect(HermesEventMapper.toolStatus("new-status") == .running)
    }
}
