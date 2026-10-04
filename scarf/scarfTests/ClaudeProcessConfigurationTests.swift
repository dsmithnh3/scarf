import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Claude Code process configuration")
struct ClaudeProcessConfigurationTests {
    @Test("new session uses structured persistent stream mode")
    func newSessionCommand() {
        let configuration = ClaudeLaunchConfiguration(
            executable: "/Users/test/.local/bin/claude",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            sessionID: "11111111-1111-4111-8111-111111111111",
            modelID: "opus"
        )

        let command = ClaudeProcessConfiguration.command(for: configuration)
        #expect(command.executable == "/Users/test/.local/bin/claude")
        #expect(command.workingDirectory.path == "/tmp/project")
        #expect(command.arguments.contains("-p"))
        #expect(command.arguments.contains("--input-format"))
        #expect(command.arguments.contains("stream-json"))
        #expect(command.arguments.contains("--output-format"))
        #expect(command.arguments.contains("--verbose"))
        #expect(command.arguments.contains("--include-partial-messages"))
        #expect(command.arguments.contains("--session-id"))
        #expect(command.arguments.contains("11111111-1111-4111-8111-111111111111"))
        #expect(command.arguments.contains("--model"))
        #expect(command.arguments.contains("opus"))
        #expect(command.arguments.contains("--permission-mode"))
        #expect(command.arguments.contains("dontAsk"))
        #expect(!command.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("resume selects existing Claude session instead of assigning a new id")
    func resumeCommand() {
        let configuration = ClaudeLaunchConfiguration(
            executable: "/usr/local/bin/claude",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            sessionID: "existing-session",
            resume: true
        )

        let arguments = ClaudeProcessConfiguration.command(for: configuration).arguments
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains("existing-session"))
        #expect(!arguments.contains("--session-id"))
    }

    @Test("user message is encoded as one channel-framed JSON record")
    func inputEncoding() throws {
        let jsonRecord = try ClaudeProcessConfiguration.userMessageJSON("hello \"Claude\"\nnext")
        #expect(!jsonRecord.hasSuffix("\n"))

        let data = try #require(jsonRecord.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "hello \"Claude\"\nnext")
    }
}
