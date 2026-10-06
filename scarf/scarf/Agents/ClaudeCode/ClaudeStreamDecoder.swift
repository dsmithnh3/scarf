import Foundation
import ScarfCore

enum ClaudeStreamDecoderError: Error, Equatable {
    case invalidJSON
}

/// Stateful decoder for Claude Code's newline-delimited `stream-json` output.
/// Unknown event types and additive fields are deliberately ignored so a newer
/// Claude Code release does not crash Scarf merely because it emits more data.
actor ClaudeStreamDecoder {
    private struct ToolMetadata: Sendable {
        let name: String
        let command: String?
        let path: String?
    }

    private var tools: [String: ToolMetadata] = [:]

    func decode(line: String) throws -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            throw ClaudeStreamDecoderError.invalidJSON
        }

        switch json["type"] as? String {
        case "system":
            if json["subtype"] as? String == "commands_changed" {
                return decodeCommandsChanged(json)
            }
            return decodeSystem(json)
        case "stream_event":
            return decodeStreamEvent(json)
        case "assistant":
            return decodeAssistant(json)
        case "user":
            return decodeUser(json)
        case "result":
            return decodeResult(json)
        default:
            return []
        }
    }

    private func decodeSystem(_ json: [String: Any]) -> [AgentEvent] {
        guard json["subtype"] as? String == "init",
              let sessionID = json["session_id"] as? String
        else { return [] }

        let cwd = (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        var metadata: [String: String] = [:]
        if let model = json["model"] as? String, !model.isEmpty { metadata["model"] = model }
        if let version = json["claude_code_version"] as? String, !version.isEmpty {
            metadata["claudeCodeVersion"] = version
        }
        if let permissionMode = json["permissionMode"] as? String, !permissionMode.isEmpty {
            metadata["permissionMode"] = permissionMode
        }

        return [.sessionStarted(AgentSession(
            id: sessionID,
            backendID: .claudeCode,
            workingDirectory: cwd,
            metadata: metadata
        ))]
    }

    /// `commands_changed` replaces the slash list. A missing `commands` array
    /// is ignored so a partial frame cannot wipe a list the handshake stored.
    private func decodeCommandsChanged(_ json: [String: Any]) -> [AgentEvent] {
        guard let rows = json["commands"] as? [[String: Any]] else { return [] }
        let discovered = rows.compactMap { row -> AgentSlashCommandCatalogs.ClaudeDiscoveredCommand? in
            guard let name = row["name"] as? String else { return nil }
            return AgentSlashCommandCatalogs.ClaudeDiscoveredCommand(
                name: name,
                description: row["description"] as? String ?? "",
                argumentHint: row["argumentHint"] as? String,
                aliases: row["aliases"] as? [String] ?? []
            )
        }
        return [.availableCommandsUpdated(AgentSlashCommandCatalogs.claudeCodeCommands(from: discovered))]
    }

    private func decodeStreamEvent(_ json: [String: Any]) -> [AgentEvent] {
        guard let event = json["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              let type = delta["type"] as? String
        else { return [] }

        switch type {
        case "text_delta":
            guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "thinking_delta":
            guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
            return [.reasoningDelta(text)]
        default:
            return []
        }
    }

    private func decodeAssistant(_ json: [String: Any]) -> [AgentEvent] {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        var events: [AgentEvent] = []
        for block in content where block["type"] as? String == "tool_use" {
            guard let toolID = block["id"] as? String,
                  let name = block["name"] as? String
            else { continue }

            let input = block["input"] as? [String: Any] ?? [:]
            let inputJSON = jsonString(input)
            let command = input["command"] as? String
            let path = (input["file_path"] as? String) ?? (input["path"] as? String)
            tools[toolID] = ToolMetadata(name: name, command: command, path: path)

            events.append(.toolStarted(AgentToolCall(
                id: toolID,
                title: toolTitle(name: name, input: input),
                kind: name,
                status: .running,
                input: inputJSON
            )))

            if name.caseInsensitiveCompare("Bash") == .orderedSame, let command {
                events.append(.commandStarted(AgentCommand(
                    id: toolID,
                    command: command,
                    status: .running
                )))
            }
        }
        return events
    }

    private func decodeUser(_ json: [String: Any]) -> [AgentEvent] {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        var events: [AgentEvent] = []
        for block in content where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String else { continue }
            let isError = block["is_error"] as? Bool ?? false
            let output = contentText(block["content"])
            let status: AgentToolStatus = isError ? .failed : .completed

            events.append(.toolCompleted(AgentToolResult(
                toolCallID: toolID,
                status: status,
                output: output,
                errorMessage: isError ? output : nil
            )))

            if let metadata = tools.removeValue(forKey: toolID) {
                if metadata.name.caseInsensitiveCompare("Bash") == .orderedSame {
                    events.append(.commandCompleted(AgentCommandResult(
                        commandID: toolID,
                        output: isError ? nil : output,
                        errorOutput: isError ? output : nil
                    )))
                }

                if let path = metadata.path,
                   ["write", "edit", "multiedit", "notebookedit"].contains(metadata.name.lowercased()) {
                    // Claude's tool result does not reliably distinguish file
                    // creation from replacement, so report that a change
                    // occurred without inventing a more specific kind.
                    events.append(.fileChanged(AgentFileChange(
                        path: path,
                        kind: .unknown
                    )))
                }
            }
        }
        return events
    }

    private func decodeResult(_ json: [String: Any]) -> [AgentEvent] {
        let subtype = (json["subtype"] as? String) ?? "result"
        let isError = json["is_error"] as? Bool ?? subtype.hasPrefix("error")
        var events: [AgentEvent] = []

        if let usage = json["usage"] as? [String: Any] {
            events.append(.usageUpdated(AgentUsage(
                inputTokens: int(usage["input_tokens"]),
                outputTokens: int(usage["output_tokens"]),
                reasoningTokens: int(usage["thinking_tokens"]),
                cachedReadTokens: int(usage["cache_read_input_tokens"])
            )))
        }

        if isError {
            let message = (json["error"] as? String)
                ?? (json["result"] as? String)
                ?? "Claude Code ended the turn with an error"
            events.append(.error(AgentError(
                code: "claude.\(subtype)",
                message: message,
                isRecoverable: true
            )))
        }

        events.append(.turnCompleted(stopReason: subtype))
        return events
    }

    private func toolTitle(name: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String, !command.isEmpty { return command }
        if let path = (input["file_path"] as? String) ?? (input["path"] as? String), !path.isEmpty {
            return "\(name): \(path)"
        }
        return name
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func contentText(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let blocks = value as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
}
