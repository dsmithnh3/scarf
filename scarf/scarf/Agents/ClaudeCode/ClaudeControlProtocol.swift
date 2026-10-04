import Foundation

struct ClaudeControlRequest: Sendable, Equatable {
    let requestID: String
    let subtype: String
    var fields: [String: String]

    static func interrupt(requestID: String = ClaudeControlProtocol.makeRequestID()) -> ClaudeControlRequest {
        ClaudeControlRequest(requestID: requestID, subtype: "interrupt", fields: [:])
    }
}

struct ClaudeControlResponse: Sendable, Equatable {
    let requestID: String
    let isSuccess: Bool
    let errorMessage: String?
}

enum ClaudeControlProtocol {
    static func makeRequestID() -> String {
        "scarf_req_\(UUID().uuidString.lowercased())"
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
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ClaudeControlProtocolError.invalidUTF8
        }
        return json
    }

    static func decodeResponse(_ line: String) throws -> ClaudeControlResponse? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
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
}

enum ClaudeControlProtocolError: Error, Equatable {
    case invalidUTF8
    case invalidJSON
    case invalidControlResponse
}
