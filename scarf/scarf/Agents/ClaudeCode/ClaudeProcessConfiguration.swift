import Foundation

struct ClaudeLaunchConfiguration: Sendable, Equatable {
    let executable: String
    let workingDirectory: URL
    let sessionID: String
    var modelID: String?
    var resume: Bool

    init(
        executable: String,
        workingDirectory: URL,
        sessionID: String,
        modelID: String? = nil,
        resume: Bool = false
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.modelID = modelID
        self.resume = resume
    }
}

struct ClaudeProcessCommand: Sendable, Equatable {
    let executable: String
    let arguments: [String]
    let workingDirectory: URL
}

enum ClaudeProcessConfiguration {
    static func command(for configuration: ClaudeLaunchConfiguration) -> ClaudeProcessCommand {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // Verified host-prompting launch (Agent SDK canUseTool path):
            // `--permission-mode default` emits prompts; `dontAsk` never does.
            // `--permission-prompt-tool stdio` routes them over stream-json
            // control_request / can_use_tool (same flags the Agent SDK pushes).
            "--permission-mode", "default",
            "--permission-prompt-tool", "stdio",
        ]

        if configuration.resume {
            arguments += ["--resume", configuration.sessionID]
        } else {
            arguments += ["--session-id", configuration.sessionID]
        }

        if let modelID = configuration.modelID, !modelID.isEmpty {
            arguments += ["--model", modelID]
        }

        return ClaudeProcessCommand(
            executable: configuration.executable,
            arguments: arguments,
            workingDirectory: configuration.workingDirectory
        )
    }

    /// One complete JSON input record. The process channel owns newline
    /// framing and appends the terminator atomically when sending.
    static func userMessageJSON(_ text: String) throws -> String {
        let object: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [[
                    "type": "text",
                    "text": text,
                ]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ClaudeProcessConfigurationError.invalidUTF8
        }
        return json
    }
}

enum ClaudeProcessConfigurationError: Error, Equatable {
    case invalidUTF8
}
