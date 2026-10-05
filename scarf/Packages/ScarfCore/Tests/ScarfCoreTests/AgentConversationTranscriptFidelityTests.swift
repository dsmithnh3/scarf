import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent conversation transcript persistence")
struct AgentConversationTranscriptStoreTests {
    @Test("durable messages survive a store reload boundary")
    func messagesPersistAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_transcripts.json")

        let writer = AgentConversationTranscriptStore(fileURL: fileURL)
        let user = AgentMessage(role: .user, content: "Hello")
        let assistant = AgentMessage(role: .assistant, content: "Hi there")
        let usage = AgentUsage(inputTokens: 3, outputTokens: 5, reasoningTokens: 1, cachedReadTokens: 0)
        let toolResult = AgentToolResult(
            toolCallID: "tool-1",
            status: .completed,
            output: "ok"
        )
        try writer.save(
            AgentConversationTranscript(
                conversationID: "conv-1",
                messages: [user, assistant],
                toolResults: ["tool-1": toolResult],
                usage: usage
            )
        )

        let reader = AgentConversationTranscriptStore(fileURL: fileURL)
        let loaded = try #require(try reader.load(conversationID: "conv-1"))
        #expect(loaded.messages.map(\.content) == ["Hello", "Hi there"])
        #expect(loaded.messages.map(\.role) == [.user, .assistant])
        #expect(loaded.toolResults["tool-1"] == toolResult)
        #expect(loaded.usage == usage)
    }

    @Test("durable activity fields survive a store reload boundary")
    func activityFieldsPersistAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_transcripts.json")

        let toolCall = AgentToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .completed,
            input: "README.md"
        )
        let toolResult = AgentToolResult(
            toolCallID: "tool-1",
            status: .completed,
            output: "contents"
        )
        let command = AgentCommand(id: "cmd-1", command: "git status", status: .completed)
        let commandResult = AgentCommandResult(commandID: "cmd-1", exitCode: 0, output: "clean")
        let file = AgentFileChange(path: "/tmp/project/file.swift", kind: .modified, diff: "+line")
        let usage = AgentUsage(inputTokens: 3, outputTokens: 5, reasoningTokens: 1, cachedReadTokens: 0)

        let writer = AgentConversationTranscriptStore(fileURL: fileURL)
        try writer.save(
            AgentConversationTranscript(
                conversationID: "conv-1",
                messages: [AgentMessage(role: .user, content: "Do work")],
                toolResults: ["tool-1": toolResult],
                usage: usage,
                toolCalls: [toolCall],
                commands: [command],
                commandOutput: ["cmd-1": "clean\n"],
                commandResults: ["cmd-1": commandResult],
                fileChanges: [file],
                reasoningBlocks: ["Inspecting context"]
            )
        )

        let reader = AgentConversationTranscriptStore(fileURL: fileURL)
        let loaded = try #require(try reader.load(conversationID: "conv-1"))
        #expect(loaded.toolCalls == [toolCall])
        #expect(loaded.toolResults["tool-1"] == toolResult)
        #expect(loaded.commands == [command])
        #expect(loaded.commandOutput["cmd-1"] == "clean\n")
        #expect(loaded.commandResults["cmd-1"] == commandResult)
        #expect(loaded.fileChanges == [file])
        #expect(loaded.reasoningBlocks == ["Inspecting context"])
        #expect(loaded.usage == usage)
    }

    @Test("legacy transcripts decode with empty activity defaults")
    func legacyTranscriptDecodesWithoutActivityKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_transcripts.json")

        // First-slice JSON shape: messages / toolResults / usage only.
        let legacy = """
        {
          "transcripts" : {
            "conv-1" : {
              "conversationID" : "conv-1",
              "messages" : [
                {
                  "content" : "Hello",
                  "id" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                  "role" : "user"
                }
              ],
              "toolResults" : {

              },
              "usage" : {
                "cachedReadTokens" : 0,
                "inputTokens" : 1,
                "outputTokens" : 2,
                "reasoningTokens" : 0
              }
            }
          }
        }
        """
        try Data(legacy.utf8).write(to: fileURL)

        let reader = AgentConversationTranscriptStore(fileURL: fileURL)
        let loaded = try #require(try reader.load(conversationID: "conv-1"))
        #expect(loaded.messages.map(\.content) == ["Hello"])
        #expect(loaded.toolCalls.isEmpty)
        #expect(loaded.commands.isEmpty)
        #expect(loaded.commandOutput.isEmpty)
        #expect(loaded.commandResults.isEmpty)
        #expect(loaded.fileChanges.isEmpty)
        #expect(loaded.reasoningBlocks.isEmpty)
        #expect(loaded.usage?.inputTokens == 1)
    }

    @Test("remove clears transcript so a reload finds nothing")
    func removeClearsAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-agent-transcript-rm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("agent_conversation_transcripts.json")

        let writer = AgentConversationTranscriptStore(fileURL: fileURL)
        try writer.save(
            AgentConversationTranscript(
                conversationID: "conv-1",
                messages: [AgentMessage(role: .user, content: "gone")]
            )
        )
        try writer.remove(conversationID: "conv-1")

        let reader = AgentConversationTranscriptStore(fileURL: fileURL)
        #expect(try reader.load(conversationID: "conv-1") == nil)
    }
}

@Suite("Agent conversation controller transcript fidelity")
struct AgentConversationControllerTranscriptFidelityTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>

        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var nextSessionNumber = 0

        init(id: AgentID = .claudeCode, displayName: String = "Claude Code") {
            self.id = id
            self.displayName = displayName
            var continuation: AsyncStream<AgentEvent>.Continuation!
            self.events = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus { .available(version: nil) }
        nonisolated func models() async throws -> [AgentModel] { [] }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            nextSessionNumber += 1
            return AgentSession(
                id: "session-\(nextSessionNumber)",
                backendID: id,
                workingDirectory: configuration.workingDirectory
            )
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession { session }

        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func emit(_ event: AgentEvent) {
            continuation.yield(event)
        }
    }

    @Test("restorePersistedSession rehydrates durable messages across reload")
    func restoreRehydratesMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)

        let first = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: identityStore,
            transcriptStore: transcriptStore
        )
        let started = try await first.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp/project")
            )
        )
        try await first.send("Hello from user")

        let completedState = Task<AgentConversationState?, Never> {
            for await state in first.stateUpdates {
                if state.stopReason == "end_turn",
                   state.messages.map(\.content) == ["Hello from user", "Hello back"],
                   state.usage?.inputTokens == 11 {
                    return state
                }
            }
            return nil
        }

        await backend.emit(.textStarted)
        await backend.emit(.textDelta("Hello back"))
        await backend.emit(.textCompleted)
        await backend.emit(
            .usageUpdated(
                AgentUsage(inputTokens: 11, outputTokens: 7, reasoningTokens: 0, cachedReadTokens: 2)
            )
        )
        await backend.emit(.turnCompleted(stopReason: "end_turn"))
        _ = try #require(await completedState.value)
        _ = started

        // Relaunch without close: identity + transcript must survive.
        let second = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )
        let restored = try #require(await second.restorePersistedSession())
        #expect(restored.id == started.id)

        let after = await second.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Hello from user", "Hello back"])
        #expect(after.messages.map(\.role) == [.user, .assistant])
        #expect(after.usage?.inputTokens == 11)
        #expect(after.usage?.outputTokens == 7)
    }

    @Test("restorePersistedSession rehydrates activity fields across reload")
    func restoreRehydratesActivityFields() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")
        let identityStore = AgentConversationIdentityStore(fileURL: identityURL)
        let transcriptStore = AgentConversationTranscriptStore(fileURL: transcriptURL)

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)

        let first = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: identityStore,
            transcriptStore: transcriptStore
        )
        let started = try await first.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp/project")
            )
        )
        try await first.send("Do work")

        let tool = AgentToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .running,
            input: "README.md"
        )
        let completedTool = AgentToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .completed,
            input: "README.md"
        )
        let toolResult = AgentToolResult(
            toolCallID: "tool-1",
            status: .completed,
            output: "contents"
        )
        let command = AgentCommand(id: "cmd-1", command: "git status", status: .running)
        let commandResult = AgentCommandResult(commandID: "cmd-1", exitCode: 0, output: "clean")
        let file = AgentFileChange(path: "/tmp/project/file.swift", kind: .modified)

        let completedState = Task<AgentConversationState?, Never> {
            for await state in first.stateUpdates {
                if state.stopReason == "end_turn",
                   state.toolCalls == [completedTool],
                   state.toolResults["tool-1"] == toolResult,
                   state.commands.first?.status == .completed,
                   state.commandOutput["cmd-1"] == "line 1\nline 2",
                   state.commandResults["cmd-1"] == commandResult,
                   state.fileChanges == [file],
                   state.reasoningBlocks == ["Inspecting context"],
                   state.messages.map(\.content) == ["Do work", "Done"] {
                    return state
                }
            }
            return nil
        }

        await backend.emit(.reasoningStarted)
        await backend.emit(.reasoningDelta("Inspecting context"))
        await backend.emit(.reasoningCompleted)
        await backend.emit(.toolStarted(tool))
        await backend.emit(.toolUpdated(completedTool))
        await backend.emit(.toolCompleted(toolResult))
        await backend.emit(.commandStarted(command))
        await backend.emit(.commandOutput(commandID: "cmd-1", text: "line 1\n"))
        await backend.emit(.commandOutput(commandID: "cmd-1", text: "line 2"))
        await backend.emit(.commandCompleted(commandResult))
        await backend.emit(.fileChanged(file))
        await backend.emit(.textStarted)
        await backend.emit(.textDelta("Done"))
        await backend.emit(.textCompleted)
        await backend.emit(.turnCompleted(stopReason: "end_turn"))
        _ = try #require(await completedState.value)
        _ = started

        let second = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )
        _ = try #require(await second.restorePersistedSession())

        let after = await second.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Do work", "Done"])
        #expect(after.toolCalls == [completedTool])
        #expect(after.toolResults["tool-1"] == toolResult)
        #expect(after.commands == [AgentCommand(id: "cmd-1", command: "git status", status: .completed)])
        #expect(after.commandOutput["cmd-1"] == "line 1\nline 2")
        #expect(after.commandResults["cmd-1"] == commandResult)
        #expect(after.fileChanges == [file])
        #expect(after.reasoningBlocks == ["Inspecting context"])
        #expect(after.reasoningDraft.isEmpty)
        #expect(after.assistantDraft.isEmpty)
        #expect(after.permissionRequest == nil)
    }

    @Test("close removes persisted transcript")
    func closeRemovesTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-ctrl-transcript-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identityURL = directory.appendingPathComponent("agent_conversation_identities.json")
        let transcriptURL = directory.appendingPathComponent("agent_conversation_transcripts.json")

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)
        let controller = AgentConversationController(
            coordinator: coordinator,
            conversationID: "window-1",
            identityStore: AgentConversationIdentityStore(fileURL: identityURL),
            transcriptStore: AgentConversationTranscriptStore(fileURL: transcriptURL)
        )
        _ = try await controller.startSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration()
        )
        try await controller.send("temp")
        try await controller.close()

        let reloaded = AgentConversationTranscriptStore(fileURL: transcriptURL)
        #expect(try reloaded.load(conversationID: "window-1") == nil)
    }

    @Test("makePersisting restores durable messages via production transcript path")
    func makePersistingRestoresTranscript() async throws {
        let hermesHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-prod-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hermesHome) }
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)

        let expectedURL = AgentConversationTranscriptStore.productionFileURL(
            hermesHome: hermesHome.path
        )
        #expect(expectedURL.path.hasSuffix("/scarf/agent_conversation_transcripts.json"))

        let coordinator = AgentCoordinator()
        let backend = RecordingBackend()
        await coordinator.register(backend)

        let conversationID = UUID().uuidString
        let controller = AgentConversationController.makePersisting(
            coordinator: coordinator,
            conversationID: conversationID,
            hermesHome: hermesHome.path
        )
        let started = try await controller.startOrRestorePersistedSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp/project")
            )
        )
        try await controller.send("Persisted hello")

        let completedState = Task<AgentConversationState?, Never> {
            for await state in controller.stateUpdates {
                if state.messages.map(\.content) == ["Persisted hello", "Persisted reply"] {
                    return state
                }
            }
            return nil
        }
        await backend.emit(.textDelta("Persisted reply"))
        await backend.emit(.textCompleted)
        _ = try #require(await completedState.value)
        _ = started

        #expect(FileManager.default.fileExists(atPath: expectedURL.path))

        let relaunched = AgentConversationController.makePersisting(
            coordinator: coordinator,
            conversationID: conversationID,
            hermesHome: hermesHome.path
        )
        _ = try await relaunched.startOrRestorePersistedSession(
            backendID: .claudeCode,
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp/project")
            )
        )
        let after = await relaunched.stateSnapshot()
        #expect(after.messages.map(\.content) == ["Persisted hello", "Persisted reply"])
    }
}
