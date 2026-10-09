import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Agent chat model selection")
@MainActor
struct AgentChatViewModelModelSelectionTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>
        private let continuation: AsyncStream<AgentEvent>.Continuation
        private(set) var createConfigurations: [AgentSessionConfiguration] = []
        private(set) var setModelCalls: [(sessionID: String, modelID: String, providerID: String?)] = []
        private var nextSessionNumber = 0
        private var modelsList: [AgentModel]
        private var setModelError: Error?

        init(id: AgentID, displayName: String, models: [AgentModel] = []) {
            self.id = id
            self.displayName = displayName
            self.modelsList = models
            var continuation: AsyncStream<AgentEvent>.Continuation!
            self.events = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        nonisolated func installationStatus() async -> AgentInstallationStatus {
            .available(version: "test")
        }

        nonisolated func models() async throws -> [AgentModel] {
            await modelsList
        }

        func createSession(configuration: AgentSessionConfiguration) async throws -> AgentSession {
            createConfigurations.append(configuration)
            nextSessionNumber += 1
            return AgentSession(
                id: "session-\(nextSessionNumber)",
                backendID: id,
                workingDirectory: configuration.workingDirectory,
                metadata: configuration.modelID.map { ["model": $0] } ?? [:]
            )
        }

        func resumeSession(_ session: AgentSession) async throws -> AgentSession { session }
        func send(_ message: AgentMessage, in session: AgentSession) async throws {}
        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {}
        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}
        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func setSessionModel(
            session: AgentSession,
            modelID: String,
            providerID: String?
        ) async throws {
            if let setModelError {
                throw setModelError
            }
            setModelCalls.append((session.id, modelID, providerID))
        }

        func failNextSetModel(_ error: Error) {
            setModelError = error
        }

        func configurations() -> [AgentSessionConfiguration] { createConfigurations }
        func modelCalls() -> [(sessionID: String, modelID: String, providerID: String?)] {
            setModelCalls
        }
    }

    @Test("first start uses nil modelID; selecting a model restarts with that id")
    func selectModelRestartsWithModelID() async throws {
        let models = [
            AgentModel(id: "default", displayName: "Default (recommended)"),
            AgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5"),
        ]
        let backend = RecordingBackend(id: .claudeCode, displayName: "Claude Code", models: models)
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let cwd = URL(fileURLWithPath: "/tmp/scarf-model-pick", isDirectory: true)

        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .claudeCode,
            workingDirectory: cwd,
            modelsLoader: { (try? await backend.models()) ?? [] }
        )

        #expect(viewModel.supportsModelPicker)
        #expect(viewModel.selectedModelID == nil)

        await viewModel.start()
        #expect(viewModel.isStarted)
        #expect(viewModel.availableModels.map(\.id) == ["default", "claude-sonnet-5"])

        let firstConfigs = await backend.configurations()
        #expect(firstConfigs.count == 1)
        #expect(firstConfigs[0].modelID == nil)

        await viewModel.selectModel(id: "claude-sonnet-5")
        #expect(viewModel.selectedModelID == "claude-sonnet-5")
        #expect(viewModel.modelBadgeLabel == "Sonnet 5")

        let configs = await backend.configurations()
        #expect(configs.count == 2)
        #expect(configs[1].modelID == "claude-sonnet-5")
        #expect(configs[1].workingDirectory == cwd)
        #expect(await backend.modelCalls().isEmpty)
    }

    @Test("Hermes picker is available when catalog models are non-empty")
    func hermesSupportsPickerWhenModelsPresent() async {
        let backend = RecordingBackend(
            id: .hermes,
            displayName: "Hermes",
            models: [AgentModel(id: "openrouter:anthropic/claude-sonnet-5", displayName: "Sonnet 5")]
        )
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            modelsLoader: { (try? await backend.models()) ?? [] }
        )
        #expect(!viewModel.supportsModelPicker)
        await viewModel.start()
        #expect(viewModel.supportsModelPicker)
        #expect(viewModel.modelPickerHelp.contains("live"))
    }

    @Test("Hermes selecting a model calls set_model without creating a second session")
    func hermesSelectModelUsesLiveSetModel() async throws {
        let pickerID = "openrouter:anthropic/claude-sonnet-5"
        let backend = RecordingBackend(
            id: .hermes,
            displayName: "Hermes",
            models: [
                AgentModel(id: "openrouter:openai/gpt-5.5", displayName: "GPT-5.5"),
                AgentModel(id: pickerID, displayName: "Sonnet 5"),
            ]
        )
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-hermes-model", isDirectory: true),
            modelsLoader: { (try? await backend.models()) ?? [] }
        )

        await viewModel.start()
        #expect(await backend.configurations().count == 1)

        await viewModel.selectModel(id: pickerID)
        #expect(viewModel.selectedModelID == pickerID)
        #expect(viewModel.modelBadgeLabel == "Sonnet 5")
        #expect(await backend.configurations().count == 1)

        let calls = await backend.modelCalls()
        #expect(calls.count == 1)
        #expect(calls[0].sessionID == "session-1")
        #expect(calls[0].modelID == "anthropic/claude-sonnet-5")
        #expect(calls[0].providerID == "openrouter")
    }

    @Test("Hermes set_model failure reverts the selected model id")
    func hermesSelectModelFailureReverts() async throws {
        let first = "openrouter:openai/gpt-5.5"
        let second = "openrouter:anthropic/claude-sonnet-5"
        let backend = RecordingBackend(
            id: .hermes,
            displayName: "Hermes",
            models: [
                AgentModel(id: first, displayName: "GPT-5.5"),
                AgentModel(id: second, displayName: "Sonnet 5"),
            ]
        )
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            modelsLoader: { (try? await backend.models()) ?? [] }
        )

        await viewModel.start()
        await viewModel.selectModel(id: first)
        #expect(viewModel.selectedModelID == first)

        await backend.failNextSetModel(
            AgentError(code: "hermes.busy", message: "busy", isRecoverable: true)
        )
        await viewModel.selectModel(id: second)
        #expect(viewModel.selectedModelID == first)
        #expect(await controller.stateSnapshot().error?.code == "conversation.set-model-failed")
    }

    @Test("Hermes ignores model selection while a turn is running")
    func hermesIgnoresSelectWhileRunning() async throws {
        let backend = RecordingBackend(
            id: .hermes,
            displayName: "Hermes",
            models: [
                AgentModel(id: "openrouter:a", displayName: "A"),
                AgentModel(id: "openrouter:b", displayName: "B"),
            ]
        )
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            modelsLoader: { (try? await backend.models()) ?? [] }
        )

        await viewModel.start()
        // Drive isRunning via a user turn start on the controller state path.
        try await controller.send("hello")
        for _ in 0..<50 {
            if viewModel.state.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(viewModel.state.isRunning)

        await viewModel.selectModel(id: "openrouter:b")
        #expect(viewModel.selectedModelID == nil)
        #expect(await backend.modelCalls().isEmpty)
    }

    @Test("selecting the same model is a no-op")
    func selectingSameModelIsNoOp() async throws {
        let backend = RecordingBackend(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5")]
        )
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .claudeCode,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            modelsLoader: { (try? await backend.models()) ?? [] }
        )

        await viewModel.start()
        await viewModel.selectModel(id: "claude-sonnet-5")
        let afterFirst = await backend.configurations().count
        await viewModel.selectModel(id: "claude-sonnet-5")
        let afterSecond = await backend.configurations().count
        #expect(afterSecond == afterFirst)
    }
}
