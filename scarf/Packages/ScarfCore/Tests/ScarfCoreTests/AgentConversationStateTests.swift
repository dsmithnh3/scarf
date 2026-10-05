import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation state")
struct AgentConversationStateTests {
    @Test("streamed assistant text commits exactly once")
    func streamedTextCommits() {
        var state = AgentConversationState()
        state.beginUserTurn("Hello")

        #expect(state.messages.count == 1)
        #expect(state.messages[0].role == .user)
        #expect(state.messages[0].content == "Hello")
        #expect(state.isRunning)

        state.apply(.textStarted)
        state.apply(.textDelta("Hi"))
        state.apply(.textDelta(" there"))

        #expect(state.assistantDraft == "Hi there")
        #expect(state.messages.count == 1)

        state.apply(.textCompleted)
        #expect(state.assistantDraft.isEmpty)
        #expect(state.messages.count == 2)
        #expect(state.messages[1].role == .assistant)
        #expect(state.messages[1].content == "Hi there")

        // A backend may emit turnCompleted after textCompleted. The already
        // committed assistant message must not be duplicated.
        state.apply(.turnCompleted(stopReason: "end_turn"))
        #expect(state.messages.count == 2)
        #expect(!state.isRunning)
        #expect(state.stopReason == "end_turn")
    }

    @Test("turn completion flushes an unfinished text and reasoning draft")
    func turnCompletionFlushesDrafts() {
        var state = AgentConversationState()
        state.beginUserTurn("Explain")
        state.apply(.reasoningStarted)
        state.apply(.reasoningDelta("Inspecting context"))
        state.apply(.textStarted)
        state.apply(.textDelta("Partial answer"))

        state.apply(.turnCompleted(stopReason: nil))

        #expect(state.reasoningDraft.isEmpty)
        #expect(state.reasoningBlocks == ["Inspecting context"])
        #expect(state.assistantDraft.isEmpty)
        #expect(state.messages.last?.role == .assistant)
        #expect(state.messages.last?.content == "Partial answer")
        #expect(!state.isRunning)
    }

    @Test("tool command file and usage events remain backend neutral")
    func activityEvents() {
        var state = AgentConversationState()
        let tool = AgentToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .running,
            input: "README.md"
        )
        let updatedTool = AgentToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .completed,
            input: "README.md"
        )
        let result = AgentToolResult(
            toolCallID: "tool-1",
            status: .completed,
            output: "contents"
        )
        let command = AgentCommand(id: "cmd-1", command: "git status", status: .running)
        let commandResult = AgentCommandResult(commandID: "cmd-1", exitCode: 0, output: "clean")
        let file = AgentFileChange(path: "/tmp/project/file.swift", kind: .modified)
        let usage = AgentUsage(inputTokens: 10, outputTokens: 20, reasoningTokens: 3, cachedReadTokens: 4)

        state.apply(.toolStarted(tool))
        state.apply(.toolUpdated(updatedTool))
        state.apply(.toolCompleted(result))
        state.apply(.commandStarted(command))
        state.apply(.commandOutput(commandID: "cmd-1", text: "line 1\n"))
        state.apply(.commandOutput(commandID: "cmd-1", text: "line 2"))
        state.apply(.commandCompleted(commandResult))
        state.apply(.fileChanged(file))
        state.apply(.usageUpdated(usage))

        #expect(state.toolCalls == [updatedTool])
        #expect(state.toolResults["tool-1"] == result)
        #expect(state.commands.first?.status == .completed)
        #expect(state.commandOutput["cmd-1"] == "line 1\nline 2")
        #expect(state.commandResults["cmd-1"] == commandResult)
        #expect(state.fileChanges == [file])
        #expect(state.usage == usage)
    }

    @Test("restoreDurableTranscript rehydrates activity and aligns result statuses")
    func restoreDurableActivityFields() {
        var state = AgentConversationState()
        let toolCall = AgentToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .running,
            input: "README.md"
        )
        let toolResult = AgentToolResult(
            toolCallID: "tool-1",
            status: .completed,
            output: "contents"
        )
        let command = AgentCommand(id: "cmd-1", command: "git status", status: .running)
        let commandResult = AgentCommandResult(commandID: "cmd-1", exitCode: 1, output: "dirty")
        let file = AgentFileChange(path: "/tmp/a.swift", kind: .created)
        let usage = AgentUsage(inputTokens: 2, outputTokens: 3, reasoningTokens: 1, cachedReadTokens: 0)

        state.restoreDurableTranscript(
            messages: [AgentMessage(role: .user, content: "Hi")],
            toolResults: ["tool-1": toolResult],
            usage: usage,
            toolCalls: [toolCall],
            commands: [command],
            commandOutput: ["cmd-1": "dirty\n"],
            commandResults: ["cmd-1": commandResult],
            fileChanges: [file],
            reasoningBlocks: ["Thinking"]
        )

        #expect(state.messages.map(\.content) == ["Hi"])
        #expect(state.toolCalls == [
            AgentToolCall(
                id: "tool-1",
                title: "Read file",
                kind: "read",
                status: .completed,
                input: "README.md"
            )
        ])
        #expect(state.toolResults["tool-1"] == toolResult)
        #expect(state.commands == [
            AgentCommand(id: "cmd-1", command: "git status", status: .failed)
        ])
        #expect(state.commandOutput["cmd-1"] == "dirty\n")
        #expect(state.commandResults["cmd-1"] == commandResult)
        #expect(state.fileChanges == [file])
        #expect(state.reasoningBlocks == ["Thinking"])
        #expect(state.usage == usage)
        #expect(state.reasoningDraft.isEmpty)
        #expect(state.assistantDraft.isEmpty)
        #expect(state.permissionRequest == nil)
        #expect(!state.isRunning)
    }

    @Test("session permission error and close lifecycle is explicit")
    func lifecycleEvents() {
        var state = AgentConversationState()
        let session = AgentSession(
            id: "session-1",
            backendID: .claudeCode,
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let permission = AgentPermissionRequest(
            id: "permission-1",
            title: "Run command",
            detail: "git status",
            options: [AgentPermissionOption(id: "allow", title: "Allow")]
        )
        let recoverable = AgentError(code: "transport", message: "retry", isRecoverable: true)

        state.apply(.sessionStarted(session))
        #expect(state.session == session)
        #expect(!state.isClosed)

        state.apply(.permissionRequested(permission))
        #expect(state.permissionRequest == permission)

        state.apply(.error(recoverable))
        #expect(state.error == recoverable)

        state.apply(.sessionClosed)
        #expect(state.isClosed)
        #expect(!state.isRunning)
        #expect(state.permissionRequest == nil)
    }
}
