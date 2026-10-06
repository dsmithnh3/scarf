import Foundation

struct ClaudeControlRequest: Sendable, Equatable {
    let requestID: String
    let subtype: String
    var fields: [String: String]

    static func interrupt(requestID: String = ClaudeControlProtocol.makeRequestID()) -> ClaudeControlRequest {
        ClaudeControlRequest(requestID: requestID, subtype: "interrupt", fields: [:])
    }
}

struct ClaudePermissionControlRequest: Sendable, Equatable {
    let requestID: String
    let toolName: String
    let inputJSON: String
}

struct ClaudeControlResponse: Sendable, Equatable {
    let requestID: String
    let isSuccess: Bool
    let errorMessage: String?
}

enum ClaudePermissionDecision: Sendable, Equatable {
    case allow(updatedInputJSON: String? = nil)
    case deny(message: String)
}

struct ClaudeInitializeModel: Sendable, Equatable {
    let value: String
    let displayName: String
}

struct ClaudeInitializeCommand: Sendable, Equatable {
    let name: String
    let description: String
    let argumentHint: String
    let aliases: [String]
    let isBuiltin: Bool
}

/// Non-secret account fields from initialize. Email and organization are not kept.
struct ClaudeInitializeAccount: Sendable, Equatable {
    var subscriptionType: String?
    var tokenSource: String?
    var apiKeySource: String?
    var apiProvider: String?
}

struct ClaudeInitializeResult: Sendable, Equatable {
    var models: [ClaudeInitializeModel]
    var commands: [ClaudeInitializeCommand]
    var account: ClaudeInitializeAccount
}

enum ClaudeControlProtocol {
    static func makeRequestID() -> String {
        "scarf_req_\(UUID().uuidString.lowercased())"
    }

    static func encodeInitialize(requestID: String = ClaudeControlProtocol.makeRequestID()) throws -> String {
        let envelope: [String: Any] = [
            "type": "control_request",
            "request_id": requestID,
            "request": ["subtype": "initialize"],
        ]
        return try jsonString(envelope)
    }

    /// Decode the success payload of a control `initialize` response.
    ///
    /// Returns nil for every other control response (interrupt acks, errors)
    /// and when neither `models` nor `commands` is present (older CLI).
    static func decodeInitializeResult(_ line: String) throws -> ClaudeInitializeResult? {
        guard let json = try decodeJSONObject(line) else {
            throw ClaudeControlProtocolError.invalidJSON
        }
        guard json["type"] as? String == "control_response",
              let response = json["response"] as? [String: Any],
              response["subtype"] as? String == "success",
              let payload = response["response"] as? [String: Any]
        else { return nil }

        let hasModels = payload["models"] != nil
        let hasCommands = payload["commands"] != nil
        guard hasModels || hasCommands else { return nil }

        guard let models = decodeModels(payload["models"]),
              let commands = decodeCommands(payload["commands"])
        else { return nil }

        return ClaudeInitializeResult(
            models: models,
            commands: commands,
            account: decodeAccount(payload["account"])
        )
    }

    static func encode(_ request: ClaudeControlRequest) throws -> String {
        var body: [String: Any] = ["subtype": request.subtype]
        for (key, value) in request.fields {
            body[key] = value
        }
        let envelope: [String: Any] = [
            "type": "control_request",
            "request_id": request.requestID,
            "request": body,
        ]
        return try jsonString(envelope)
    }

    /// Decode a host-facing Claude Code control request.
    ///
    /// Only `can_use_tool` is surfaced here. Unknown control request subtypes
    /// remain available to future protocol handlers without being mistaken for
    /// permission prompts.
    static func decodePermissionRequest(_ line: String) throws -> ClaudePermissionControlRequest? {
        guard let json = try decodeJSONObject(line) else {
            throw ClaudeControlProtocolError.invalidJSON
        }
        guard json["type"] as? String == "control_request" else { return nil }
        guard let requestID = json["request_id"] as? String,
              let request = json["request"] as? [String: Any],
              let subtype = request["subtype"] as? String
        else {
            throw ClaudeControlProtocolError.invalidControlRequest
        }
        guard subtype == "can_use_tool" else { return nil }
        guard let toolName = request["tool_name"] as? String else {
            throw ClaudeControlProtocolError.invalidPermissionRequest
        }

        let input = request["input"] ?? [:]
        guard JSONSerialization.isValidJSONObject(input) else {
            throw ClaudeControlProtocolError.invalidPermissionRequest
        }
        let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        guard let inputJSON = String(data: inputData, encoding: .utf8) else {
            throw ClaudeControlProtocolError.invalidUTF8
        }
        return ClaudePermissionControlRequest(
            requestID: requestID,
            toolName: toolName,
            inputJSON: inputJSON
        )
    }

    /// Encode the response shape Claude Code expects for a `can_use_tool`
    /// request. Used by the host permission bridge when launch uses
    /// `--permission-mode default` + `--permission-prompt-tool stdio`.
    static func encodePermissionResponse(
        requestID: String,
        decision: ClaudePermissionDecision
    ) throws -> String {
        let decisionBody: [String: Any]
        switch decision {
        case .allow(let updatedInputJSON):
            var response: [String: Any] = ["behavior": "allow"]
            if let updatedInputJSON {
                guard let inputObject = try decodeJSONFragment(updatedInputJSON) else {
                    throw ClaudeControlProtocolError.invalidPermissionInput
                }
                response["updatedInput"] = inputObject
            }
            decisionBody = response
        case .deny(let message):
            decisionBody = [
                "behavior": "deny",
                "message": message,
            ]
        }

        let envelope: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": decisionBody,
            ],
        ]
        return try jsonString(envelope)
    }

    static func decodeResponse(_ line: String) throws -> ClaudeControlResponse? {
        guard let json = try decodeJSONObject(line) else {
            throw ClaudeControlProtocolError.invalidJSON
        }
        guard json["type"] as? String == "control_response" else { return nil }
        guard let response = json["response"] as? [String: Any],
              let requestID = response["request_id"] as? String,
              let subtype = response["subtype"] as? String
        else {
            throw ClaudeControlProtocolError.invalidControlResponse
        }
        return ClaudeControlResponse(
            requestID: requestID,
            isSuccess: subtype == "success",
            errorMessage: response["error"] as? String
        )
    }

    private static func decodeModels(_ value: Any?) -> [ClaudeInitializeModel]? {
        if value == nil { return [] }
        guard let rows = value as? [[String: Any]] else { return nil }
        var models: [ClaudeInitializeModel] = []
        for row in rows {
            guard let modelValue = row["value"] as? String, !modelValue.isEmpty else { continue }
            let displayName = (row["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? modelValue
            models.append(ClaudeInitializeModel(value: modelValue, displayName: displayName))
        }
        return models
    }

    private static func decodeCommands(_ value: Any?) -> [ClaudeInitializeCommand]? {
        if value == nil { return [] }
        guard let rows = value as? [[String: Any]] else { return nil }
        var commands: [ClaudeInitializeCommand] = []
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            let aliases = row["aliases"] as? [String] ?? []
            commands.append(ClaudeInitializeCommand(
                name: name,
                description: row["description"] as? String ?? "",
                argumentHint: row["argumentHint"] as? String ?? "",
                aliases: aliases,
                isBuiltin: row["builtin"] as? Bool ?? false
            ))
        }
        return commands
    }

    private static func decodeAccount(_ value: Any?) -> ClaudeInitializeAccount {
        let object = value as? [String: Any] ?? [:]
        return ClaudeInitializeAccount(
            subscriptionType: object["subscriptionType"] as? String,
            tokenSource: object["tokenSource"] as? String,
            apiKeySource: object["apiKeySource"] as? String,
            apiProvider: object["apiProvider"] as? String
        )
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ClaudeControlProtocolError.invalidUTF8
        }
        return json
    }

    private static func decodeJSONObject(_ line: String) throws -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any]
    }

    private static func decodeJSONFragment(_ raw: String) throws -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

enum ClaudeControlProtocolError: Error, Equatable {
    case invalidUTF8
    case invalidJSON
    case invalidControlRequest
    case invalidControlResponse
    case invalidPermissionRequest
    case invalidPermissionInput
}
