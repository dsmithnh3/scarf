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
        #expect(!capabilities.contains(.permissions))
        #expect(!capabilities.contains(.cron))
        #expect(!capabilities.contains(.gateway))
        #expect(!capabilities.contains(.proxy))
    }

    @Test("missing Claude executable reports not installed")
    func missingInstallation() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { nil },
            installationProbe: { _ in .available(version: "should-not-run") },
            environmentProvider: { [:] }
        )
        #expect(await backend.installationStatus() == .notInstalled)
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
    }

    @Test("permission responses fail explicitly until host permission bridge is implemented")
    func permissionsUnsupported() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { "/tmp/claude" },
            installationProbe: { _ in .available(version: nil) },
            environmentProvider: { [:] }
        )
        let session = AgentSession(id: "s", backendID: .claudeCode)
        let request = AgentPermissionRequest(id: "p", title: "Approve")

        do {
            try await backend.respond(to: request, optionID: "allow", in: session)
            Issue.record("Expected unsupported permissions error")
        } catch let error as AgentError {
            #expect(error.code == "claude.permissions-not-implemented")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try await backend.cancelPermission(request, in: session)
            Issue.record("Expected unsupported permissions error on cancel")
        } catch let error as AgentError {
            #expect(error.code == "claude.permissions-not-implemented")
        } catch {
            Issue.record("Unexpected error: \(error)")
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
