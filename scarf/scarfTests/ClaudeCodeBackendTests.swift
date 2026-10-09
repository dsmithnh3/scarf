import Foundation
import Testing
import ScarfCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import scarf

@Suite("Claude Code agent backend")
struct ClaudeCodeBackendTests {
    @Test("Claude advertises only capabilities implemented by the backend")
    func capabilitiesAreConservative() {
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .available(version: "test") },
            environmentProvider: { [:] }
        )
        let capabilities = backend.capabilities

        #expect(backend.id == .claudeCode)
        #expect(backend.displayName == "Claude Code")
        #expect(capabilities.contains(.streaming))
        #expect(capabilities.contains(.reasoning))
        #expect(capabilities.contains(.toolCalls))
        #expect(capabilities.contains(.sessions))
        #expect(capabilities.contains(.resume))
        #expect(capabilities.contains(.mcp))
        #expect(capabilities.contains(.usage))
        #expect(capabilities.contains(.fileChanges))
        #expect(capabilities.contains(.shellCommands))
        // Host-prompting launch (`default` + `--permission-prompt-tool stdio`)
        // plus receive/answer round trip justify advertising `.permissions`.
        #expect(capabilities.contains(.permissions))
        #expect(!capabilities.contains(.cron))
        #expect(!capabilities.contains(.gateway))
        #expect(!capabilities.contains(.proxy))
    }

    @Test("host-prompting launch mode plus receive/answer round trip justifies .permissions")
    func hostPromptingModeJustifiesPermissionsCapability() async throws {
        // 1) Launch args must use the verified host-prompting flags.
        let launch = ClaudeLaunchConfiguration(
            executable: "/tmp/claude",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            sessionID: "33333333-3333-4333-8333-333333333333"
        )
        let arguments = ClaudeProcessConfiguration.command(for: launch).arguments
        #expect(arguments.contains("--permission-mode"))
        #expect(arguments.contains("default"))
        #expect(arguments.contains("--permission-prompt-tool"))
        #expect(arguments.contains("stdio"))
        #expect(!arguments.contains("dontAsk"))

        // 2) Backend both receives can_use_tool and answers allow under that mode.
        let channel = PermissionMockChannel()
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .available(version: "host-prompt") },
            environmentProvider: { [:] },
            channelFactory: { _, _ in channel }
        )
        #expect(backend.capabilities.contains(.permissions))

        let collector = PermissionEventCollector()
        let collectTask = Task { await collector.consume(backend.events) }

        let session = try await backend.createSession(
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )
        )

        let permissionLine = #"{"type":"control_request","request_id":"req_host","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/a.txt","content":"hello"}}}"#
        await channel.emit(permissionLine)

        let request = try await collector.nextPermission()
        #expect(request.id == "req_host")
        #expect(request.detail == "can_use_tool")

        try await backend.respond(to: request, optionID: "allow", in: session)

        let sent = try await channel.waitForSentCount(2)
        let responseLine = try #require(sent.last { $0.contains("\"request_id\":\"req_host\"") })
        let data = try #require(responseLine.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "control_response")
        let outer = try #require(json["response"] as? [String: Any])
        #expect(outer["request_id"] as? String == "req_host")
        let response = try #require(outer["response"] as? [String: Any])
        #expect(response["behavior"] as? String == "allow")

        await backend.close(session: session)
        collectTask.cancel()
    }

    @Test("initialize handshake caches models, publishes commands, and strips API keys from the child env")
    func initializeHandshakePublishesModelsAndCommands() async throws {
        let channel = PermissionMockChannel()
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .available(version: "2.1.289") },
            environmentProvider: {
                [
                    "PATH": "/usr/bin",
                    "ANTHROPIC_API_KEY": "stale-gui-key",
                    "SCARF_KEEP": "yes",
                ]
            },
            authStatusProbe: { _, _ in .notProbed },
            channelFactory: { _, environment in
                #expect(environment["ANTHROPIC_API_KEY"] == nil)
                #expect(environment["PATH"] == "/usr/bin")
                #expect(environment["SCARF_KEEP"] == "yes")
                return channel
            }
        )
        let collector = CommandEventCollector()
        let collectTask = Task { await collector.consume(backend.events) }

        let session = try await backend.createSession(
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )
        )

        let sent = try await channel.waitForSentCount(1)
        let initData = try #require(sent[0].data(using: .utf8))
        let initJSON = try #require(JSONSerialization.jsonObject(with: initData) as? [String: Any])
        let requestID = try #require(initJSON["request_id"] as? String)
        let request = try #require(initJSON["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "initialize")

        let response = """
        {"type":"control_response","response":{"subtype":"success","request_id":"\(requestID)","response":{"models":[{"value":"default","displayName":"Default (recommended)"}],"commands":[{"name":"help","description":"Show help","argumentHint":""}],"account":{"apiProvider":"firstParty"}}}}
        """
        await channel.emit(response)

        let commands = try await collector.nextCommands()
        #expect(commands.map(\.name) == ["help"])
        #expect(commands.first?.source == .claudeCode)
        let models = try await backend.models()
        #expect(models.map(\.id) == ["default"])
        #expect(models.map(\.displayName) == ["Default (recommended)"])

        await channel.emit(
            #"{"type":"system","subtype":"commands_changed","commands":[{"name":"review","description":"Review","argumentHint":"[path]"}]}"#
        )
        let replaced = try await collector.nextCommands()
        #expect(replaced.map(\.name) == ["review"])

        await backend.close(session: session)
        collectTask.cancel()
    }

    @Test("can_use_tool mapper exposes allow/deny options for coordinator answer")
    func permissionRequestMapper() {
        let control = ClaudePermissionControlRequest(
            requestID: "req_map",
            toolName: "Bash",
            inputJSON: #"{"command":"ls"}"#
        )
        let request = ClaudeCodeBackend.permissionRequest(from: control)
        #expect(request.id == "req_map")
        #expect(request.title == "Bash")
        #expect(request.detail == "can_use_tool")
        #expect(request.options.map(\.id) == ["allow", "deny"])
    }

    @Test("missing Claude executable reports not installed")
    func missingInstallation() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { nil },
            installationProbe: { _ in .available(version: "should-not-run") },
            environmentProvider: { [:] }
        )
        #expect(await backend.installationStatus() == .notInstalled)
        #expect(backend.resolvedExecutablePath() == nil)
    }

    @Test("installation probe receives resolved executable")
    func installationProbe() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { "/custom/claude" },
            installationProbe: { executable in
                executable == "/custom/claude"
                    ? .available(version: "2.1-test")
                    : .unavailable(reason: "wrong executable")
            },
            environmentProvider: { [:] }
        )
        #expect(await backend.installationStatus() == .available(version: "2.1-test"))
        #expect(backend.resolvedExecutablePath() == "/custom/claude")
    }

    @Test("permission respond/cancel require an active Claude session")
    func permissionsRequireActiveSession() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .available(version: nil) },
            environmentProvider: { [:] }
        )
        let session = AgentSession(id: "s", backendID: .claudeCode)
        let request = AgentPermissionRequest(
            id: "p",
            title: "Write",
            detail: "can_use_tool",
            options: [
                AgentPermissionOption(id: "allow", title: "Allow"),
                AgentPermissionOption(id: "deny", title: "Deny"),
            ]
        )

        do {
            try await backend.respond(to: request, optionID: "allow", in: session)
            Issue.record("Expected session-not-active for respond")
        } catch let error as AgentError {
            #expect(error.code == "claude.session-not-active")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await backend.cancelPermission(request, in: session)
            Issue.record("Expected session-not-active for cancel")
        } catch let error as AgentError {
            #expect(error.code == "claude.session-not-active")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("can_use_tool control_request becomes permissionRequested and allow writes control_response")
    func canUseToolRoundTripAllowViaChannel() async throws {
        let channel = PermissionMockChannel()
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .available(version: "channel-test") },
            environmentProvider: { [:] },
            channelFactory: { _, _ in channel }
        )
        let collector = PermissionEventCollector()
        let collectTask = Task { await collector.consume(backend.events) }

        let session = try await backend.createSession(
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )
        )

        let permissionLine = #"{"type":"control_request","request_id":"req_perm","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/a.txt","content":"hello"}}}"#
        await channel.emit(permissionLine)

        let request = try await collector.nextPermission()
        #expect(request.id == "req_perm")
        #expect(request.title == "Write")
        #expect(request.detail == "can_use_tool")
        #expect(request.options.map(\.id) == ["allow", "deny"])

        try await backend.respond(to: request, optionID: "allow", in: session)

        let sent = try await channel.waitForSentCount(2)
        let responseLine = try #require(sent.last { $0.contains("\"request_id\":\"req_perm\"") })
        let data = try #require(responseLine.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "control_response")
        let outer = try #require(json["response"] as? [String: Any])
        #expect(outer["request_id"] as? String == "req_perm")
        let response = try #require(outer["response"] as? [String: Any])
        #expect(response["behavior"] as? String == "allow")
        let updatedInput = try #require(response["updatedInput"] as? [String: Any])
        #expect(updatedInput["file_path"] as? String == "/tmp/a.txt")

        await backend.close(session: session)
        collectTask.cancel()
    }

    @Test("cancelPermission writes deny control_response for pending can_use_tool")
    func canUseToolRoundTripCancelViaChannel() async throws {
        let channel = PermissionMockChannel()
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .available(version: "channel-test") },
            environmentProvider: { [:] },
            channelFactory: { _, _ in channel }
        )
        let collector = PermissionEventCollector()
        let collectTask = Task { await collector.consume(backend.events) }

        let session = try await backend.createSession(
            configuration: AgentSessionConfiguration(
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )
        )

        let permissionLine = #"{"type":"control_request","request_id":"req_cancel","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
        await channel.emit(permissionLine)
        let request = try await collector.nextPermission()

        try await backend.cancelPermission(request, in: session)

        let sent = try await channel.waitForSentCount(2)
        let responseLine = try #require(sent.last { $0.contains("\"request_id\":\"req_cancel\"") })
        let data = try #require(responseLine.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outer = try #require(json["response"] as? [String: Any])
        #expect(outer["request_id"] as? String == "req_cancel")
        let response = try #require(outer["response"] as? [String: Any])
        #expect(response["behavior"] as? String == "deny")
        #expect(response["message"] as? String == "Cancelled by user")

        await backend.close(session: session)
        collectTask.cancel()
    }

    @Test("conversation controller allow round-trips Claude can_use_tool through coordinator")
    func controllerAllowRoundTripThroughCoordinator() async throws {
        try await ClaudeProcessLifecycleProbe.withSession(
            script: ClaudeProcessLifecycleProbe.permissionPromptScript
        ) { probe in
            let ready = try await probe.nextText()
            #expect(ready == "ready")

            let pending = try await probe.waitForState {
                $0.permissionCoordinator.pending.contains(where: { $0.id == "req_perm_1" })
            }
            let presented = try #require(pending.permissionCoordinator.presented)
            #expect(presented.id == "req_perm_1")
            #expect(presented.backendID == .claudeCode)
            #expect(presented.category == "can_use_tool")
            #expect(presented.description == "Write")
            #expect(presented.options.map(\.id) == ["allow", "deny"])
            #expect(pending.permissionRequest?.id == "req_perm_1")

            try await probe.controller.respond(
                to: presented.asAgentPermissionRequest,
                optionID: "allow"
            )

            let allowed = try await probe.nextText()
            #expect(allowed == "allowed")

            let after = await probe.controller.stateSnapshot()
            #expect(after.permissionCoordinator.pending.isEmpty)
            #expect(after.permissionRequest == nil)
            #expect(after.permissionCoordinator.records.first { $0.id == "req_perm_1" }?.status == .answered)
            #expect(after.permissionCoordinator.records.first { $0.id == "req_perm_1" }?.selectedOptionID == "allow")
        }
    }

    @Test("conversation controller cancel round-trips Claude can_use_tool deny response")
    func controllerCancelRoundTripThroughCoordinator() async throws {
        try await ClaudeProcessLifecycleProbe.withSession(
            script: ClaudeProcessLifecycleProbe.permissionPromptScript
        ) { probe in
            let ready = try await probe.nextText()
            #expect(ready == "ready")

            let pending = try await probe.waitForState {
                $0.permissionCoordinator.pending.contains(where: { $0.id == "req_perm_1" })
            }
            let presented = try #require(pending.permissionCoordinator.presented)

            try await probe.controller.cancelPermission(presented.asAgentPermissionRequest)

            let denied = try await probe.nextText()
            #expect(denied == "denied")

            let after = await probe.controller.stateSnapshot()
            #expect(after.permissionCoordinator.pending.isEmpty)
            #expect(after.permissionRequest == nil)
            #expect(after.permissionCoordinator.records.first { $0.id == "req_perm_1" }?.status == .cancelled)
        }
    }

    @Test("unavailable installation probe is surfaced without claiming availability")
    func unavailableInstallation() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .unavailable(reason: "version probe failed") },
            environmentProvider: { [:] }
        )
        #expect(await backend.installationStatus() == .unavailable(reason: "version probe failed"))
    }

    @Test("createSession fails when Claude executable is missing")
    func createSessionRequiresExecutable() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { nil },
            installationProbe: { _ in .available(version: "should-not-run") },
            environmentProvider: { [:] }
        )
        do {
            _ = try await backend.createSession(configuration: AgentSessionConfiguration())
            Issue.record("Expected claude.not-installed")
        } catch let error as AgentError {
            #expect(error.code == "claude.not-installed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("resumeSession fails when Claude executable is missing")
    func resumeSessionRequiresExecutable() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { nil },
            installationProbe: { _ in .available(version: "should-not-run") },
            environmentProvider: { [:] }
        )
        let session = AgentSession(id: "existing", backendID: .claudeCode)
        do {
            _ = try await backend.resumeSession(session)
            Issue.record("Expected claude.not-installed")
        } catch let error as AgentError {
            #expect(error.code == "claude.not-installed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("resume keeps the requested Claude session identity when the runtime is already active")
    func resumeKeepsRequestedIdentity() async throws {
        try await ClaudeProcessLifecycleProbe.withSession { probe in
            let ready = try await probe.nextText()
            #expect(ready == "ready")
            let before = try #require(await probe.controller.stateSnapshot().session)

            let resumed = try await probe.controller.resumeSession(before)
            #expect(resumed.id == before.id)
            #expect(resumed.backendID == .claudeCode)
            #expect((await probe.controller.stateSnapshot()).session?.id == before.id)
            #expect(!(await probe.controller.stateSnapshot()).isClosed)

            try await probe.controller.send("next")
            let ack = try await probe.nextText()
            #expect(ack == "ack")
        }
    }

    @Test("system init that reports a different session id keeps Scarf routing identity")
    func divergentSystemInitKeepsRoutingIdentity() async throws {
        try await ClaudeProcessLifecycleProbe.withSession(
            script: ClaudeProcessLifecycleProbe.divergentSessionScript
        ) { probe in
            let ready = try await probe.nextText()
            #expect(ready == "ready")

            let state = try await probe.waitForState {
                $0.assistantDraft.contains("ready")
                    || $0.messages.contains { $0.role == .assistant && $0.content.contains("ready") }
            }
            let activeID = try #require(state.session?.id)
            #expect(activeID != "claude-reported-id")
            #expect(state.session?.metadata["claudeReportedSessionID"] == "claude-reported-id")

            try await probe.controller.send("next")
            let ack = try await probe.nextText()
            #expect(ack == "ack")
            let afterAck = try await probe.waitForState {
                $0.assistantDraft.contains("ack")
                    || $0.messages.contains { $0.role == .assistant && $0.content.contains("ack") }
            }
            #expect(afterAck.session?.id == activeID)
        }
    }

    @Test("unexpected Claude process exit surfaces conversation error state")
    func unexpectedProcessExitSurfacesConversationError() async throws {
        try await ClaudeProcessLifecycleProbe.withSession(
            script: ClaudeProcessLifecycleProbe.exitAfterReadyScript
        ) { probe in
            let ready = try await probe.nextText()
            #expect(ready == "ready")

            let state = try await probe.waitForState { $0.error?.code == "claude.process-ended" }
            #expect(state.error?.code == "claude.process-ended")
            #expect(state.error?.isRecoverable == true)
            #expect(!state.isClosed)
        }
    }

    @Test("closing the conversation terminates the Claude Code process")
    func conversationCloseTerminatesClaudeProcess() async throws {
        try await ClaudeProcessLifecycleProbe.withSession { probe in
            let ready = try await probe.nextText()
            #expect(ready == "ready")

            try await probe.controller.close()

            try await probe.expectProcessExited()
            let state = await probe.controller.stateSnapshot()
            #expect(state.isClosed)
            #expect(await probe.errorCodes().isEmpty)

            do {
                try await probe.controller.send("after close")
                Issue.record("Closed conversation accepted another turn")
            } catch let error as AgentConversationControllerError {
                #expect(error == .noActiveSession)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("cancelling a turn interrupts Claude Code without terminating its process")
    func turnCancelInterruptsClaudeWithoutTerminatingProcess() async throws {
        try await ClaudeProcessLifecycleProbe.withSession { probe in
            let ready = try await probe.nextText()
            #expect(ready == "ready")

            try await probe.controller.cancel()
            let interrupted = try await probe.nextText()
            #expect(interrupted == "interrupted")
            #expect(!(await probe.controller.stateSnapshot()).isClosed)

            try await probe.controller.send("next")
            let ack = try await probe.nextText()
            #expect(ack == "ack")

            try await probe.controller.close()
            try await probe.expectProcessExited()
            #expect((await probe.controller.stateSnapshot()).isClosed)
            #expect(await probe.errorCodes().isEmpty)
        }
    }
}

/// Drives the real Claude process channel through the conversation controller.
///
/// The stand-in executable speaks the stream-json subset the backend already
/// decodes and holds a FIFO open for its whole life. Conversation close must
/// make that FIFO reach EOF. Turn cancel must deliver a control interrupt and
/// leave the process able to accept another user message.
private final class ClaudeProcessLifecycleProbe {
    let controller: AgentConversationController
    private let fifoPath: String
    private let logPath: String
    private let collector: TextCollector
    private let exitWatch: Task<Void, Error>
    private let collectTask: Task<Void, Never>

    /// Failure bound only. Success returns when the FIFO reaches EOF or the
    /// next stream line arrives; this deadline exists so a leaked process
    /// fails the test instead of hanging the suite.
    private static let failureBoundNanoseconds: UInt64 = 5_000_000_000

    static func withSession(
        script: String = ClaudeProcessLifecycleProbe.script,
        _ body: (ClaudeProcessLifecycleProbe) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifoPath = directory.appendingPathComponent("lifetime").path
        let logPath = directory.appendingPathComponent("trace.log").path
        let executable = directory.appendingPathComponent("claude")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        guard mkfifo(fifoPath, mode_t(0o600)) == 0 else {
            throw ClaudeProcessLifecycleError.posix("mkfifo", errno)
        }

        let exitWatch = Task.detached {
            try Self.readUntilEOF(fifoPath)
        }
        let collector = TextCollector()
        let backend = ClaudeCodeBackend(
            executableResolver: { executable.path },
            installationProbe: { _ in .available(version: "lifecycle-test") },
            environmentProvider: {
                [
                    "SCARF_CLAUDE_LIFECYCLE_FIFO": fifoPath,
                    "SCARF_CLAUDE_LIFECYCLE_LOG": logPath,
                ]
            }
        )
        let collectTask = Task { await collector.consume(backend.events) }
        let coordinator = AgentCoordinator()
        await coordinator.register(backend)
        let controller = AgentConversationController(coordinator: coordinator)
        let probe = ClaudeProcessLifecycleProbe(
            controller: controller,
            fifoPath: fifoPath,
            logPath: logPath,
            collector: collector,
            exitWatch: exitWatch,
            collectTask: collectTask
        )

        do {
            _ = try await controller.startSession(
                backendID: .claudeCode,
                configuration: AgentSessionConfiguration(workingDirectory: directory)
            )
            try await body(probe)
            if !(await controller.stateSnapshot()).isClosed {
                try await controller.close()
            }
            try await probe.expectProcessExited()
        } catch {
            if !(await controller.stateSnapshot()).isClosed {
                try? await controller.close()
            }
            probe.terminateStandIn()
            await probe.unblockExitWatch()
            _ = try? await exitWatch.value
            collectTask.cancel()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        collectTask.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    func nextText() async throws -> String {
        try await first(failure: .timedOut) {
            try await self.collector.nextText()
        }
    }

    func errorCodes() async -> [String] {
        await collector.errorCodes()
    }

    func expectProcessExited() async throws {
        try await first(failure: .processStillRunning) {
            try await self.exitWatch.value
        }
    }

    func waitForState(
        _ predicate: @escaping @Sendable (AgentConversationState) -> Bool
    ) async throws -> AgentConversationState {
        if predicate(await controller.stateSnapshot()) {
            return await controller.stateSnapshot()
        }
        return try await first(failure: .timedOut) {
            for await state in self.controller.stateUpdates {
                if predicate(state) { return state }
            }
            throw ClaudeProcessLifecycleError.streamEnded
        }
    }

    fileprivate init(
        controller: AgentConversationController,
        fifoPath: String,
        logPath: String,
        collector: TextCollector,
        exitWatch: Task<Void, Error>,
        collectTask: Task<Void, Never>
    ) {
        self.controller = controller
        self.fifoPath = fifoPath
        self.logPath = logPath
        self.collector = collector
        self.exitWatch = exitWatch
        self.collectTask = collectTask
    }

    /// Resolves with whichever finishes first. The loser is cancelled and not
    /// awaited, so a blocked FIFO read cannot trap the timeout error inside
    /// task-group teardown.
    private func first<T: Sendable>(
        failure: ClaudeProcessLifecycleError,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let box = FirstResult<T>()
        let worker = Task {
            do { box.succeed(try await operation()) }
            catch { box.fail(error) }
        }
        let timer = Task {
            do {
                try await Task.sleep(nanoseconds: Self.failureBoundNanoseconds)
                box.fail(failure)
            } catch {
                // Cancelled because the operation won.
            }
        }
        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
            }
            worker.cancel()
            timer.cancel()
            return value
        } catch {
            worker.cancel()
            timer.cancel()
            throw error
        }
    }

    private func terminateStandIn() {
        guard let trace = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        for line in trace.split(separator: "\n") where line.hasPrefix("pid ") {
            guard let pid = Int32(line.dropFirst(4)), pid > 0 else { continue }
            _ = kill(pid, SIGKILL)
        }
    }

    private func unblockExitWatch() async {
        let path = fifoPath
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let descriptor = open(path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 {
                    close(descriptor)
                }
                continuation.resume()
            }
        }
    }

    private static func readUntilEOF(_ path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ClaudeProcessLifecycleError.posix("open", errno)
        }
        defer { close(descriptor) }
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw ClaudeProcessLifecycleError.posix("read", errno)
            }
        }
    }

    private static let script = """
    #!/usr/bin/python3
    import json, os, sys

    fifo = os.open(os.environ["SCARF_CLAUDE_LIFECYCLE_FIFO"], os.O_WRONLY)
    log = open(os.environ["SCARF_CLAUDE_LIFECYCLE_LOG"], "w", buffering=1)
    log.write("pid %s\\n" % os.getpid())

    def emit(text):
        frame = {
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "delta": {"type": "text_delta", "text": text},
            },
        }
        sys.stdout.write(json.dumps(frame, separators=(",", ":")) + "\\n")
        sys.stdout.flush()
        log.write("emit %s\\n" % text)

    emit("ready")
    while True:
        line = sys.stdin.readline()
        if line == "":
            log.write("stdin eof\\n")
            break
        log.write("in %s" % line)
        if '"subtype":"interrupt"' in line:
            emit("interrupted")
        elif '"type":"user"' in line:
            emit("ack")
    os.close(fifo)
    log.write("exit\\n")
    """

    /// Emits one text frame then exits so the stdout stream ends while the
    /// backend still tracks the runtime — the unexpected-exit error path.
    static let exitAfterReadyScript = """
    #!/usr/bin/python3
    import json, os, sys

    fifo = os.open(os.environ["SCARF_CLAUDE_LIFECYCLE_FIFO"], os.O_WRONLY)
    log = open(os.environ["SCARF_CLAUDE_LIFECYCLE_LOG"], "w", buffering=1)
    log.write("pid %s\\n" % os.getpid())

    frame = {
        "type": "stream_event",
        "event": {
            "type": "content_block_delta",
            "delta": {"type": "text_delta", "text": "ready"},
        },
    }
    sys.stdout.write(json.dumps(frame, separators=(",", ":")) + "\\n")
    sys.stdout.flush()
    log.write("emit ready\\n")
    os.close(fifo)
    log.write("exit\\n")
    """

    /// Emits a system init whose session_id intentionally differs from Scarf's
    /// `--session-id`, then streams text under that divergent identity.
    static let divergentSessionScript = """
    #!/usr/bin/python3
    import json, os, sys

    fifo = os.open(os.environ["SCARF_CLAUDE_LIFECYCLE_FIFO"], os.O_WRONLY)
    log = open(os.environ["SCARF_CLAUDE_LIFECYCLE_LOG"], "w", buffering=1)
    log.write("pid %s\\n" % os.getpid())

    def emit_obj(obj):
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\\n")
        sys.stdout.flush()

    def emit(text):
        emit_obj({
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "delta": {"type": "text_delta", "text": text},
            },
        })
        log.write("emit %s\\n" % text)

    emit_obj({
        "type": "system",
        "subtype": "init",
        "session_id": "claude-reported-id",
        "cwd": os.getcwd(),
        "model": "opus",
    })
    log.write("init divergent\\n")
    emit("ready")
    while True:
        line = sys.stdin.readline()
        if line == "":
            log.write("stdin eof\\n")
            break
        log.write("in %s" % line)
        if '"type":"user"' in line:
            emit("ack")
    os.close(fifo)
    log.write("exit\\n")
    """

    /// Emits ready text then a can_use_tool control_request; answers with text
    /// when the host writes allow/deny control_response frames.
    static let permissionPromptScript = """
    #!/usr/bin/python3
    import json, os, sys

    fifo = os.open(os.environ["SCARF_CLAUDE_LIFECYCLE_FIFO"], os.O_WRONLY)
    log = open(os.environ["SCARF_CLAUDE_LIFECYCLE_LOG"], "w", buffering=1)
    log.write("pid %s\\n" % os.getpid())

    def emit_obj(obj):
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\\n")
        sys.stdout.flush()

    def emit(text):
        emit_obj({
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "delta": {"type": "text_delta", "text": text},
            },
        })
        log.write("emit %s\\n" % text)

    emit("ready")
    emit_obj({
        "type": "control_request",
        "request_id": "req_perm_1",
        "request": {
            "subtype": "can_use_tool",
            "tool_name": "Write",
            "input": {"file_path": "/tmp/a.txt", "content": "hello"},
        },
    })
    log.write("emit permission\\n")
    while True:
        line = sys.stdin.readline()
        if line == "":
            log.write("stdin eof\\n")
            break
        log.write("in %s" % line)
        if '"type":"control_response"' in line and '"behavior":"allow"' in line:
            emit("allowed")
        elif '"type":"control_response"' in line and '"behavior":"deny"' in line:
            emit("denied")
        elif '"subtype":"interrupt"' in line:
            emit("interrupted")
        elif '"type":"user"' in line:
            emit("ack")
    os.close(fifo)
    log.write("exit\\n")
    """
}

/// Channel stand-in that can push Claude stdout lines and capture stdin writes.
private actor PermissionMockChannel: ACPChannel {
    nonisolated let incoming: AsyncThrowingStream<String, Error>
    nonisolated let stderr: AsyncThrowingStream<String, Error>
    private let incomingContinuation: AsyncThrowingStream<String, Error>.Continuation
    private var sent: [String] = []
    private var sentWaiters: [CheckedContinuation<[String], Error>] = []
    private var closed = false

    init() {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        incoming = AsyncThrowingStream { continuation = $0 }
        incomingContinuation = continuation
        stderr = AsyncThrowingStream { $0.finish() }
    }

    func emit(_ line: String) {
        incomingContinuation.yield(line)
    }

    func send(_ line: String) async throws {
        sent.append(line)
        let waiters = sentWaiters
        sentWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: sent)
        }
    }

    func close() async {
        closed = true
        incomingContinuation.finish()
    }

    var diagnosticID: String? { "permission-mock" }
    var lastExitCode: Int32? { closed ? 0 : nil }

    func waitForSentCount(_ count: Int) async throws -> [String] {
        if sent.count >= count { return sent }
        return try await withCheckedThrowingContinuation { continuation in
            sentWaiters.append(continuation)
        }
    }
}

private actor CommandEventCollector {
    private var commands: [[AgentSlashCommandDescriptor]] = []
    private var waiters: [CheckedContinuation<[AgentSlashCommandDescriptor], Error>] = []

    func consume(_ events: AsyncStream<AgentEvent>) async {
        for await event in events {
            guard case .availableCommandsUpdated(let commands) = event else { continue }
            if waiters.isEmpty {
                self.commands.append(commands)
            } else {
                waiters.removeFirst().resume(returning: commands)
            }
        }
    }

    func nextCommands() async throws -> [AgentSlashCommandDescriptor] {
        if !commands.isEmpty { return commands.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor PermissionEventCollector {
    private var permissions: [AgentPermissionRequest] = []
    private var waiters: [CheckedContinuation<AgentPermissionRequest, Error>] = []

    func consume(_ events: AsyncStream<AgentEvent>) async {
        for await event in events {
            guard case .permissionRequested(let request) = event else { continue }
            if waiters.isEmpty {
                permissions.append(request)
            } else {
                waiters.removeFirst().resume(returning: request)
            }
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: ClaudeProcessLifecycleError.streamEnded)
        }
    }

    func nextPermission() async throws -> AgentPermissionRequest {
        if !permissions.isEmpty {
            return permissions.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor TextCollector {
    private var texts: [String] = []
    private var errors: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []

    func consume(_ events: AsyncStream<AgentEvent>) async {
        for await event in events {
            switch event {
            case .textDelta(let text):
                if waiters.isEmpty {
                    texts.append(text)
                } else {
                    waiters.removeFirst().resume(returning: text)
                }
            case .error(let error):
                errors.append(error.code)
            default:
                break
            }
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: ClaudeProcessLifecycleError.streamEnded)
        }
    }

    func nextText() async throws -> String {
        if !texts.isEmpty {
            return texts.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func errorCodes() -> [String] { errors }
}

private enum ClaudeProcessLifecycleError: Error {
    case posix(String, Int32)
    case streamEnded
    case timedOut
    case processStillRunning
}

/// Delivers the first result to a continuation and ignores the rest.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var consumed = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let pending, !consumed {
            consumed = true
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
    }

    func succeed(_ value: T) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return }
        if let continuation {
            consumed = true
            continuation.resume(with: result)
        } else {
            pending = result
        }
    }
}
