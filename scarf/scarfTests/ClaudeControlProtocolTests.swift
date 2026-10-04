import Foundation
import Testing
@testable import scarf

@Suite("Claude Code control protocol")
struct ClaudeControlProtocolTests {
    @Test("interrupt request uses current Claude control envelope")
    func interruptEncoding() throws {
        let request = ClaudeControlRequest.interrupt(requestID: "req_test")
        let record = try ClaudeControlProtocol.encode(request)
        let data = try #require(record.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "control_request")
        #expect(json["request_id"] as? String == "req_test")
        let body = try #require(json["request"] as? [String: Any])
        #expect(body["subtype"] as? String == "interrupt")
    }

    @Test("success control response is correlated by request id")
    func successDecoding() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"still_queued":[]}}}"#
        let response = try #require(ClaudeControlProtocol.decodeResponse(line))
        #expect(response.requestID == "req_1")
        #expect(response.isSuccess)
        #expect(response.errorMessage == nil)
    }

    @Test("error control response preserves the error message")
    func errorDecoding() throws {
        let line = #"{"type":"control_response","response":{"subtype":"error","request_id":"req_2","error":"not supported"}}"#
        let response = try #require(ClaudeControlProtocol.decodeResponse(line))
        #expect(response.requestID == "req_2")
        #expect(!response.isSuccess)
        #expect(response.errorMessage == "not supported")
    }

    @Test("ordinary stream frames are not mistaken for control responses")
    func ignoresNonControlFrames() throws {
        #expect(try ClaudeControlProtocol.decodeResponse(#"{"type":"assistant","message":{}}"#) == nil)
    }

    @Test("request ids are unique and use a recognizable prefix")
    func requestIdentifiers() {
        let first = ClaudeControlProtocol.makeRequestID()
        let second = ClaudeControlProtocol.makeRequestID()
        #expect(first != second)
        #expect(first.hasPrefix("scarf_req_"))
        #expect(second.hasPrefix("scarf_req_"))
    }
}
