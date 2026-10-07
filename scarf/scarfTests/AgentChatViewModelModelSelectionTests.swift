import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Agent chat model selection")
@MainActor
struct AgentChatViewModelModelSelectionTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID = .claudeCode
        nonisolated let displayName = "Claude Code"
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions]
        nonisolated let events: AsyncStream<AgentEvent>
        private let continuation: AsyncStream<AgentEvent>.Continuation
        private(set) var createConfigurations: [AgentSessionConfiguration] = []
        private var nextSessionNumber = 0
        private var modelsList: [AgentModel]

        init(models: [AgentModel] = []) {
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

        func configurations() -> [AgentSessionConfiguration] { createConfigurations }
    }

    @Test("first start uses nil modelID; selecting a model restarts with that id")
    func selectModelRestartsWithModelID() async throws {
        let models = [
            AgentModel(id: "default", displayName: "Default (recommended)"),
            AgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5"),
        ]
        let backend = RecordingBackend(models: models)
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let cwd = URL(fileURLWithPath: "/tmp/scarf-model-pick", isDirectory: true)

        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .claudeCode,
            workingDirectory: cwd,
            modelsLoader: { try await backend.models() }
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
    }

    @Test("Hermes does not expose a model picker")
    func hermesStaysBadgeOnly() {
        let coordinator = AgentCoordinator()
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        #expect(!viewModel.supportsModelPicker)
    }

    @Test("selecting the same model is a no-op")
    func selectingSameModelIsNoOp() async throws {
        let backend = RecordingBackend(models: [
            AgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5"),
        ])
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .claudeCode,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            modelsLoader: { try await backend.models() }
        )

        await viewModel.start()
        await viewModel.selectModel(id: "claude-sonnet-5")
        let afterFirst = await backend.configurations().count
        await viewModel.selectModel(id: "claude-sonnet-5")
        let afterSecond = await backend.configurations().count
        #expect(afterSecond == afterFirst)
    }
}
