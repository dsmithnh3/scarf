import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Claude stream JSON decoder")
struct ClaudeStreamDecoderTests {
    @Test("system init identifies the Claude session")
    func systemInit() async throws {
        let decoder = ClaudeStreamDecoder()
        let events = try await decoder.decode(line: #"{"type":"system","subtype":"init","session_id":"session-1","cwd":"/tmp/project","model":"opus"}"#)
        #expect(events == [.sessionStarted(AgentSession(
            id: "session-1",
            backendID: .claudeCode,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            metadata: ["model": "opus"]
        ))])
    }

    @Test("commands_changed replaces the slash list and hook noise is ignored")
    func commandsChanged() async throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"{"type":"system","subtype":"commands_changed","commands":[{"name":"review","description":"Review the diff","argumentHint":"[path]"}],"session_id":"s"}"#
        let events = try await decoder.decode(line: line)
        guard case .availableCommandsUpdated(let commands) = events.first else {
            Issue.record("expected availableCommandsUpdated")
            return
        }
        #expect(commands.map(\.name) == ["review"])
        #expect(commands.first?.argumentHint == "[path]")
        #expect(commands.first?.source == .claudeCode)
        let hooks = try await decoder.decode(line: #"{"type":"system","subtype":"hook_started","session_id":"s"}"#)
        #expect(hooks.isEmpty)
    }

    @Test("partial text and thinking deltas stream incrementally")
    func partialDeltas() async throws {
        let decoder = ClaudeStreamDecoder()
        let text = try await decoder.decode(line: #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#)
        let thinking = try await decoder.decode(line: #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Reason"}}}"#)
        #expect(text == [.textDelta("Hello")])
        #expect(thinking == [.reasoningDelta("Reason")])
    }

    @Test("Bash tool use emits generic tool and command starts")
    func bashStart() async throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"{"type":"assistant","session_id":"s","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"git status"}}]}}"#
        let events = try await decoder.decode(line: line)
        #expect(events == [
            .toolStarted(AgentToolCall(id: "tool-1", title: "git status", kind: "Bash", status: .running, input: #"{"command":"git status"}"#)),
            .commandStarted(AgentCommand(id: "tool-1", command: "git status", status: .running))
        ])
    }

    @Test("tool result closes both generic tool and Bash command")
    func toolResult() async throws {
        let decoder = ClaudeStreamDecoder()
        _ = try await decoder.decode(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"git status"}}]}}"#)
        let events = try await decoder.decode(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"clean","is_error":false}]}}"#)
        #expect(events == [
            .toolCompleted(AgentToolResult(toolCallID: "tool-1", status: .completed, output: "clean")),
            .commandCompleted(AgentCommandResult(commandID: "tool-1", output: "clean"))
        ])
    }

    @Test("write tool result yields a conservative file change")
    func fileChange() async throws {
        let decoder = ClaudeStreamDecoder()
        _ = try await decoder.decode(line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-2","name":"Write","input":{"file_path":"/tmp/project/a.swift","content":"x"}}]}}"#)
        let events = try await decoder.decode(line: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-2","content":"written"}]}}"#)
        #expect(events.contains(.fileChanged(AgentFileChange(path: "/tmp/project/a.swift", kind: .unknown))))
    }

    @Test("result emits usage, error when needed, and turn completion")
    func result() async throws {
        let decoder = ClaudeStreamDecoder()
        let success = try await decoder.decode(line: #"{"type":"result","subtype":"success","session_id":"s","is_error":false,"usage":{"input_tokens":12,"output_tokens":7,"cache_read_input_tokens":3}}"#)
        #expect(success == [
            .usageUpdated(AgentUsage(inputTokens: 12, outputTokens: 7, reasoningTokens: 0, cachedReadTokens: 3)),
            .turnCompleted(stopReason: "success")
        ])

        let failure = try await decoder.decode(line: #"{"type":"result","subtype":"error_during_execution","session_id":"s","is_error":true,"error":"Permission denied"}"#)
        #expect(failure == [
            .error(AgentError(code: "claude.error_during_execution", message: "Permission denied", isRecoverable: true)),
            .turnCompleted(stopReason: "error_during_execution")
        ])
    }

    @Test("content_block_start tool_use emits early toolStarted")
    func contentBlockStartToolUse() async throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-early","name":"Bash","input":{}}}}"#
        let events = try await decoder.decode(line: line)
        #expect(events == [
            .toolStarted(AgentToolCall(id: "tool-early", title: "Bash", kind: "Bash", status: .running, input: "{}"))
        ])
    }

    @Test("input_json_delta accumulates and emits toolUpdated")
    func inputJSONDeltaUpdatesTool() async throws {
        let decoder = ClaudeStreamDecoder()
        _ = try await decoder.decode(line: #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-j","name":"Bash","input":{}}}}"#)
        let partial = try await decoder.decode(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"git "}}}"#)
        #expect(partial == [
            .toolUpdated(AgentToolCall(id: "tool-j", title: "Bash", kind: "Bash", status: .running, input: #"{"command":"git "#))
        ])
        let complete = try await decoder.decode(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"status\"}"}}}"#)
        guard case .toolUpdated(let call) = complete.first else {
            Issue.record("expected toolUpdated after complete JSON")
            return
        }
        #expect(call.id == "tool-j")
        #expect(call.input == #"{"command":"git status"}"#)
        #expect(call.title == "git status")
    }

    @Test("content_block_stop is a no-op")
    func contentBlockStopIgnored() async throws {
        let decoder = ClaudeStreamDecoder()
        let events = try await decoder.decode(line: #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#)
        #expect(events.isEmpty)
    }

    @Test("rate_limit_event becomes a recoverable error")
    func rateLimitEvent() async throws {
        let decoder = ClaudeStreamDecoder()
        let events = try await decoder.decode(line: #"{"type":"rate_limit_event","message":"Slow down","rate_limit_info":{"status":"rejected"}}"#)
        #expect(events == [
            .error(AgentError(code: "claude.rate-limit", message: "Slow down", isRecoverable: true))
        ])
        let fallback = try await decoder.decode(line: #"{"type":"rate_limit_event"}"#)
        #expect(fallback == [
            .error(AgentError(code: "claude.rate-limit", message: "Claude Code reported a rate limit", isRecoverable: true))
        ])
    }

    @Test("ExitPlanMode tool_use keeps plan text on the tool input")
    func exitPlanModeKeepsPlan() async throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan-1","name":"ExitPlanMode","input":{"plan":"1. Fix tests\n2. Ship"}}]}}"#
        let events = try await decoder.decode(line: line)
        #expect(events == [
            .toolStarted(AgentToolCall(
                id: "plan-1",
                title: "ExitPlanMode",
                kind: "ExitPlanMode",
                status: .running,
                input: #"{"plan":"1. Fix tests\n2. Ship"}"#
            ))
        ])
        #expect(AgentPlanCalloutPresenter.planText(from: [
            AgentToolCall(
                id: "plan-1",
                title: "ExitPlanMode",
                kind: "ExitPlanMode",
                status: .running,
                input: #"{"plan":"1. Fix tests\n2. Ship"}"#
            )
        ]) == "1. Fix tests\n2. Ship")
    }

    @Test("unknown additive events are ignored safely")
    func unknownEvent() async throws {
        let decoder = ClaudeStreamDecoder()
        #expect(try await decoder.decode(line: #"{"type":"future_event","new_field":123}"#) == [])
    }

    @Test("malformed JSON throws a typed decoder error")
    func malformed() async {
        let decoder = ClaudeStreamDecoder()
        do {
            _ = try await decoder.decode(line: "not-json")
            Issue.record("Expected invalidJSON")
        } catch let error as ClaudeStreamDecoderError {
            #expect(error == .invalidJSON)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
