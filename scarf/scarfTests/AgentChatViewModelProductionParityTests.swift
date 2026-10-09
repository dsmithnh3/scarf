import Foundation
import Testing
import ScarfCore
@testable import scarf

/// Production-parity (slice B) tests for `AgentChatViewModel`: resume via
/// legacy-ChatView attribution, boot-time project preset + auto-accept-edits,
/// idle `/queue` & `/steer` rewrite rules, the missing-credentials preflight
/// banner, approval-mode switching, and a permission-respond regression.
/// Follows `AgentChatViewModelModelSelectionTests`'s `RecordingBackend`
/// pattern — a fresh, file-private backend per test file.
@Suite("Agent chat production parity")
@MainActor
struct AgentChatViewModelProductionParityTests {
    private actor RecordingBackend: AgentBackend {
        nonisolated let id: AgentID
        nonisolated let displayName: String
        nonisolated let capabilities: AgentCapabilities = [.streaming, .sessions, .permissions]
        nonisolated let events: AsyncStream<AgentEvent>

        private let continuation: AsyncStream<AgentEvent>.Continuation
        private var modelsList: [AgentModel]
        private var nextSessionNumber = 0
        private var authHealthResult: AgentAuthHealth = .notProbed

        private var createConfigurations: [AgentSessionConfiguration] = []
        private var sentMessages: [String] = []
        private var setModelCalls: [(modelID: String, providerID: String?)] = []
        private var setModeCalls: [String] = []
        private var respondCalls: [(requestID: String, optionID: String)] = []
        private var setModelError: Error?
        private var setModeError: Error?

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

        func authHealth() async -> AgentAuthHealth { authHealthResult }

        func setAuthHealth(_ health: AgentAuthHealth) {
            authHealthResult = health
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

        func send(_ message: AgentMessage, in session: AgentSession) async throws {
            sentMessages.append(message.content)
        }

        func respond(to request: AgentPermissionRequest, optionID: String, in session: AgentSession) async throws {
            respondCalls.append((request.id, optionID))
        }

        func cancelPermission(_ request: AgentPermissionRequest, in session: AgentSession) async throws {}

        func cancel(session: AgentSession) async {}
        func close(session: AgentSession) async {}

        func setSessionModel(
            session: AgentSession,
            modelID: String,
            providerID: String?
        ) async throws {
            // One-shot, matching the method name: `failNextSetModel` arms
            // exactly the next call, not every call after it.
            if let error = setModelError {
                setModelError = nil
                throw error
            }
            setModelCalls.append((modelID, providerID))
        }

        func setSessionMode(session: AgentSession, modeID: String) async throws {
            if let error = setModeError {
                setModeError = nil
                throw error
            }
            setModeCalls.append(modeID)
        }

        func failNextSetModel(_ error: Error) { setModelError = error }
        func failNextSetMode(_ error: Error) { setModeError = error }

        func emit(_ event: AgentEvent) { continuation.yield(event) }

        func configurations() -> [AgentSessionConfiguration] { createConfigurations }
        func messages() -> [String] { sentMessages }
        func modelCalls() -> [(modelID: String, providerID: String?)] { setModelCalls }
        func modeCalls() -> [String] { setModeCalls }
        func responded() -> [(requestID: String, optionID: String)] { respondCalls }
    }

    /// A recent-enough Hermes version to clear every floor this slice reads:
    /// `hasACPQueue`, `hasACPSteer` (v0.13) and `hasSessionEditAutoApproval`
    /// (v0.15).
    private static let modernCapabilities = HermesCapabilities.parseLine(
        "Hermes Agent v0.21.1 (2026.9.7)"
    )

    // MARK: - Resume via legacy-ChatView attribution

    @Test("start resumes a fallback session id from attribution when Scarf's own conversation identity is empty")
    func startUsesFallbackSessionIDs() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        // No `conversationID` → `restorePersistedSession()` always returns
        // nil, exercising the fallback-ids branch of `startOrRestorePersistedSession`.
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-fallback-resume", isDirectory: true),
            fallbackSessionIDsLoader: { ["legacy-chatview-session-7"] }
        )

        await viewModel.start()

        #expect(viewModel.isStarted)
        #expect(await controller.activeSessionID() == "legacy-chatview-session-7")
        #expect(
            await backend.configurations().isEmpty,
            "a usable fallback id must resume instead of minting a fresh session"
        )
    }

    // MARK: - Boot: project model preset

    @Test("boot applies the project's bound model preset exactly once and updates the model badge")
    func bootAppliesProjectPresetOnce() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let preset = ModelPreset(name: "Sonnet", modelID: "claude-sonnet-5", providerID: "anthropic")

        var applyCallCount = 0
        var appliedPaths: [String] = []
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-preset", isDirectory: true),
            projectPath: "/projects/demo",
            projectPresetApplier: { path in
                applyCallCount += 1
                appliedPaths.append(path)
                return .applied(preset)
            }
        )

        await viewModel.start()

        #expect(applyCallCount == 1)
        #expect(appliedPaths == ["/projects/demo"])
        #expect(viewModel.selectedModelID == "anthropic:claude-sonnet-5")
    }

    @Test("boot leaves the model badge alone when the project has no preset binding")
    func bootNoPresetBindingLeavesModelUnset() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-no-preset", isDirectory: true),
            projectPresetApplier: { _ in .noBinding }
        )

        await viewModel.start()

        #expect(viewModel.selectedModelID == nil)
        #expect(await backend.modelCalls().isEmpty)
    }

    // MARK: - Boot: auto-accept edits

    @Test("boot applies accept_edits once when the project has auto-accept on and the host supports session/set_mode")
    func bootAppliesAutoAcceptEditsOnce() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let suite = "com.scarf.tests.agentchat.autoaccept.\(UUID().uuidString)"
        let store = ProjectAutoAcceptEditsStore(
            suiteName: suite,
            testServiceSuffix: "aae-\(UUID().uuidString)"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let projectPath = "/projects/auto-accept-demo"
        #expect(store.setEnabled(true, projectId: projectPath))

        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-auto-accept", isDirectory: true),
            projectPath: projectPath,
            autoAcceptStore: store,
            capabilitiesLoader: { Self.modernCapabilities }
        )

        await viewModel.start()

        #expect(viewModel.activeApprovalMode == .acceptEdits)
        #expect(await backend.modeCalls() == ["accept_edits"])
    }

    @Test("boot skips auto-accept below the session/set_mode capability floor, leaving the default mode")
    func bootSkipsAutoAcceptBelowCapabilityFloor() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let suite = "com.scarf.tests.agentchat.autoaccept.\(UUID().uuidString)"
        let store = ProjectAutoAcceptEditsStore(
            suiteName: suite,
            testServiceSuffix: "aae-\(UUID().uuidString)"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let projectPath = "/projects/auto-accept-sub-floor"
        #expect(store.setEnabled(true, projectId: projectPath))

        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-auto-accept-floor", isDirectory: true),
            projectPath: projectPath,
            autoAcceptStore: store,
            capabilitiesLoader: { .empty }
        )

        await viewModel.start()

        #expect(viewModel.activeApprovalMode == .default)
        #expect(await backend.modeCalls().isEmpty)
    }

    @Test("boot never calls session/set_mode when auto-accept is off for the project")
    func bootSkipsAutoAcceptWhenDisabled() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)

        let suite = "com.scarf.tests.agentchat.autoaccept.\(UUID().uuidString)"
        let store = ProjectAutoAcceptEditsStore(
            suiteName: suite,
            testServiceSuffix: "aae-\(UUID().uuidString)"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-auto-accept-off", isDirectory: true),
            projectPath: "/projects/auto-accept-off",
            autoAcceptStore: store,
            capabilitiesLoader: { Self.modernCapabilities }
        )

        await viewModel.start()

        #expect(viewModel.activeApprovalMode == .default)
        #expect(await backend.modeCalls().isEmpty)
    }

    // MARK: - Model switch: busy ignored, failure reverts + surfaces an error

    @Test("Hermes model switch is ignored while a turn is running")
    func busyModelSwitchIgnored() async throws {
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

    @Test("Hermes model switch failure reverts the selection and surfaces a VM-level action error")
    func modelSwitchFailureRevertsAndSetsLastActionError() async throws {
        let first = "openrouter:a"
        let second = "openrouter:b"
        let backend = RecordingBackend(
            id: .hermes,
            displayName: "Hermes",
            models: [
                AgentModel(id: first, displayName: "A"),
                AgentModel(id: second, displayName: "B"),
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
        #expect(viewModel.lastActionError == nil)

        await backend.failNextSetModel(
            AgentError(code: "hermes.busy", message: "busy", isRecoverable: true)
        )
        await viewModel.selectModel(id: second)

        #expect(viewModel.selectedModelID == first)
        #expect(viewModel.lastActionError != nil)
    }

    // MARK: - Idle /queue and /steer send path

    @Test("an idle /queue is rewritten to an ordinary prompt on the wire, with a notice")
    func idleQueueRewritesToOrdinaryPrompt() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            capabilitiesLoader: { Self.modernCapabilities }
        )

        await viewModel.start()
        #expect(!viewModel.state.isRunning)

        try await viewModel.send("/queue summarize the diff")

        #expect(await backend.messages() == ["summarize the diff"])
        #expect(viewModel.idleSlashNotice == RichChatViewModel.idleQueueNotice)
    }

    @Test("an idle /steer runs as an ordinary prompt (wire text unchanged), with a notice")
    func idleSteerRunsAsOrdinaryPrompt() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            capabilitiesLoader: { Self.modernCapabilities }
        )

        await viewModel.start()

        try await viewModel.send("/steer focus on the auth module")

        #expect(await backend.messages() == ["/steer focus on the auth module"])
        #expect(viewModel.idleSlashNotice == RichChatViewModel.idleSteerNotice)
    }

    @Test("an ordinary idle prompt carries no idle-slash notice")
    func ordinaryIdlePromptHasNoNotice() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            capabilitiesLoader: { Self.modernCapabilities }
        )

        await viewModel.start()
        try await viewModel.send("summarize the diff")

        #expect(await backend.messages() == ["summarize the diff"])
        #expect(viewModel.idleSlashNotice == nil)
    }

    // MARK: - Preflight: missing-credentials banner

    @Test("missing-credentials banner appears for Hermes but does not block start")
    func missingCredentialsBannerSurfacesButStartSucceeds() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            authHealthLoader: { .noCredentialsDetected }
        )

        #expect(!viewModel.missingCredentialsBanner)

        await viewModel.start()

        #expect(viewModel.isStarted)
        #expect(viewModel.missingCredentialsBanner)
    }

    @Test("missing-credentials banner stays off when a probe finds credentials")
    func missingCredentialsBannerStaysOffWhenCredentialsDetected() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            authHealthLoader: { .credentialsDetected }
        )

        await viewModel.start()

        #expect(viewModel.isStarted)
        #expect(!viewModel.missingCredentialsBanner)
    }

    // MARK: - Approval mode switching

    @Test("selectApprovalMode is optimistic and reverts with a VM-level error on failure")
    func selectApprovalModeRevertsOnFailure() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        await viewModel.start()
        #expect(viewModel.activeApprovalMode == .default)

        await backend.failNextSetMode(AgentError(code: "hermes.busy", message: "nope", isRecoverable: true))
        await viewModel.selectApprovalMode(.acceptEdits)

        #expect(viewModel.activeApprovalMode == .default)
        #expect(viewModel.lastActionError != nil)

        await viewModel.selectApprovalMode(.dontAsk)

        #expect(viewModel.activeApprovalMode == .dontAsk)
        #expect(await backend.modeCalls() == ["dont_ask"])
    }

    @Test("selectApprovalMode is a no-op on Claude, which has no session/set_mode RPC")
    func selectApprovalModeNoOpOnClaude() async throws {
        let backend = RecordingBackend(id: .claudeCode, displayName: "Claude Code")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .claudeCode,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        await viewModel.start()
        await viewModel.selectApprovalMode(.acceptEdits)

        #expect(viewModel.activeApprovalMode == .default)
        #expect(await backend.modeCalls().isEmpty)
    }

    // MARK: - Claude history restore notice (no JSONL invent)

    @Test("Claude start surfaces Scarf-preferring history notice when transcript is empty")
    func claudeStartSetsEmptyHistoryNotice() async throws {
        let backend = RecordingBackend(id: .claudeCode, displayName: "Claude Code")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .claudeCode,
            workingDirectory: URL(fileURLWithPath: "/tmp/scarf-claude-history", isDirectory: true)
        )

        await viewModel.start()

        #expect(viewModel.isStarted)
        #expect(viewModel.historyRestoreNotice == AgentChatViewModel.claudeHistoryRestoreNotice(messageCount: 0))
        #expect(viewModel.historyRestoreNotice?.contains("does not expose structured session history") == true)
    }

    @Test("userFacingErrorMessage maps claude.not-installed to install/login guidance")
    func userFacingClaudeNotInstalled() {
        let message = AgentChatViewModel.userFacingErrorMessage(
            AgentError(code: "claude.not-installed", message: "Claude Code executable could not be found")
        )
        #expect(message.contains("claude login"))
        #expect(message.contains("Install the Claude CLI"))
    }

    // MARK: - Permission respond regression

    @Test("permission respond still forwards through the controller (regression)")
    func permissionRespondStillWorks() async throws {
        let backend = RecordingBackend(id: .hermes, displayName: "Hermes")
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let viewModel = AgentChatViewModel(
            controller: controller,
            backendID: .hermes,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        await viewModel.start()

        let request = AgentPermissionRequest(
            id: "42",
            title: "run: ls",
            detail: "execute",
            options: [
                AgentPermissionOption(id: "allow_once", title: "Allow once"),
                AgentPermissionOption(id: "deny", title: "Deny"),
            ]
        )
        await backend.emit(.permissionRequested(request))
        for _ in 0..<50 {
            if viewModel.permissionPresentation != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(viewModel.permissionPresentation != nil)

        try await viewModel.respond(to: request, optionID: "allow_once")

        let calls = await backend.responded()
        #expect(calls.count == 1)
        #expect(calls[0].requestID == "42")
        #expect(calls[0].optionID == "allow_once")
        #expect(viewModel.permissionPresentation == nil)
    }
}
