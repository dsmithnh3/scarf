import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Claude Code process manager")
struct ClaudeProcessManagerTests {
    private actor MockChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private var sent: [String] = []
        private var closed = false

        init() {
            incoming = AsyncThrowingStream { _ in }
            stderr = AsyncThrowingStream { _ in }
        }

        func send(_ line: String) async throws { sent.append(line) }
        func close() async { closed = true }
        var diagnosticID: String? { "mock" }
        var lastExitCode: Int32? { closed ? 0 : nil }
        func sentLines() -> [String] { sent }
        func isClosed() -> Bool { closed }
    }

    @Test("manager sends Claude user messages through the shared line channel")
    func sendsMessage() async throws {
        let channel = MockChannel()
        let manager = ClaudeProcessManager(
            channelFactory: { _, _ in channel },
            environmentProvider: { ["PATH": "/test/bin"] }
        )
        let command = ClaudeProcessCommand(
            executable: "/test/bin/claude",
            arguments: ["-p"],
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )

        _ = try await manager.start(command: command)
        try await manager.sendUserMessage("hello")

        let lines = await channel.sentLines()
        #expect(lines.count == 1)
        let data = try #require(lines[0].data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "user")
    }

    @Test("manager sends interrupt through Claude control protocol without closing the process")
    func sendsInterrupt() async throws {
        let channel = MockChannel()
        let manager = ClaudeProcessManager(
            channelFactory: { _, _ in channel },
            environmentProvider: { [:] }
        )
        let command = ClaudeProcessCommand(
            executable: "/test/bin/claude",
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        _ = try await manager.start(command: command)
        let requestID = try await manager.sendInterrupt()

        let lines = await channel.sentLines()
        #expect(lines.count == 1)
        let data = try #require(lines[0].data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "control_request")
        #expect(json["request_id"] as? String == requestID)
        let request = try #require(json["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "interrupt")
        #expect(!(await channel.isClosed()))
    }

    @Test("manager closes the underlying process channel")
    func closesChannel() async throws {
        let channel = MockChannel()
        let manager = ClaudeProcessManager(
            channelFactory: { _, _ in channel },
            environmentProvider: { [:] }
        )
        let command = ClaudeProcessCommand(
            executable: "/test/bin/claude",
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        _ = try await manager.start(command: command)
        await manager.close()
        #expect(await channel.isClosed())
    }

    @Test("starting a replacement process closes the previous channel")
    func replacementClosesPriorChannel() async throws {
        let first = MockChannel()
        let second = MockChannel()
        let counter = LockedCounter()
        let manager = ClaudeProcessManager(
            channelFactory: { _, _ in
                let value = await counter.next()
                return value == 1 ? first : second
            },
            environmentProvider: { [:] }
        )
        let command = ClaudeProcessCommand(
            executable: "/test/bin/claude",
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        _ = try await manager.start(command: command)
        _ = try await manager.start(command: command)
        #expect(await first.isClosed())
        #expect(!(await second.isClosed()))
    }

    private actor LockedCounter {
        private var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }
}
