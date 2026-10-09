import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Claude Code control protocol")
struct ClaudeControlProtocolTests {
    @Test("initialize request is a minimal control_request")
    func initializeEncoding() throws {
        let line = try ClaudeControlProtocol.encodeInitialize(requestID: "req_init")
        let data = try #require(line.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "control_request")
        #expect(json["request_id"] as? String == "req_init")
        let request = try #require(json["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "initialize")
        #expect(request.count == 1)
    }

    @Test("initialize success payload decodes models, commands, agents, and non-secret account fields")
    func initializeSuccessDecoding() throws {
        let line = """
        {"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{"models":[{"value":"default","displayName":"Default (recommended)","resolvedModel":"claude-opus-5","description":"Example"}],"commands":[{"name":"help","description":"Show help","argumentHint":"","aliases":["h"],"builtin":true}],"agents":[{"name":"agent-writer","description":"Meta-agent for designing agents","model":"sonnet","unknown_field":true}],"account":{"email":"person@example.com","tokenSource":"claude.ai","apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty","subscriptionType":"pro"}}}}
        """
        let decoded = try ClaudeControlProtocol.decodeInitializeResult(line)
        let result = try #require(decoded)
        #expect(result.models == [
            ClaudeInitializeModel(value: "default", displayName: "Default (recommended)")
        ])
        #expect(result.commands == [
            ClaudeInitializeCommand(
                name: "help",
                description: "Show help",
                argumentHint: "",
                aliases: ["h"],
                isBuiltin: true
            )
        ])
        #expect(result.agents == [
            ClaudeInitializeAgent(
                name: "agent-writer",
                description: "Meta-agent for designing agents",
                model: "sonnet"
            )
        ])
        #expect(result.account.tokenSource == "claude.ai")
        #expect(result.account.apiKeySource == "ANTHROPIC_API_KEY")
        #expect(result.account.apiProvider == "firstParty")
        #expect(result.account.subscriptionType == "pro")
    }

    @Test("initialize agents map to Claude skill catalog descriptors")
    func initializeAgentsMapToClaudeSkills() {
        let descriptors = ClaudeCodeBackend.skillDescriptors(from: [
            ClaudeInitializeAgent(name: "agent-writer", description: "Meta-agent", model: "sonnet"),
            ClaudeInitializeAgent(name: "docs", description: "Docs helper", model: nil),
        ])
        #expect(descriptors.map(\.id) == [
            "claudeCodeSkill:agent-writer",
            "claudeCodeSkill:docs",
        ])
        #expect(descriptors.allSatisfy { $0.kind == .claudeCodeSkill && $0.source == .claudeCode })
        #expect(descriptors[0].description.contains("model: sonnet"))
        #expect(AgentExtensionCatalogs.claudeCodeSkills.isEmpty)

        let presentation = AgentExtensionBrowserPresenter.make(
            catalog: AgentExtensionCatalog(entries: descriptors),
            backendID: .claudeCode,
            capabilities: AgentSlashHintPresenter.defaultCapabilities(for: .claudeCode)
        )
        #expect(!presentation.isEmpty)
        #expect(presentation.sections.first { $0.kind == .claudeCodeSkill }?.rows.map(\.name)
            == ["agent-writer", "docs"])
    }

    @Test("interrupt success is not an initialize result")
    func interruptSuccessIsNotInitialize() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"still_queued":[]}}}"#
        #expect(try ClaudeControlProtocol.decodeInitializeResult(line) == nil)
    }

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
        let decoded = try ClaudeControlProtocol.decodeResponse(line)
        let response = try #require(decoded)
        #expect(response.requestID == "req_1")
        #expect(response.isSuccess)
        #expect(response.errorMessage == nil)
    }

    @Test("error control response preserves the error message")
    func errorDecoding() throws {
        let line = #"{"type":"control_response","response":{"subtype":"error","request_id":"req_2","error":"not supported"}}"#
        let decoded = try ClaudeControlProtocol.decodeResponse(line)
        let response = try #require(decoded)
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

    @Test("can_use_tool control request is decoded for host permission bridge")
    func permissionRequestDecoding() throws {
        let line = #"{"type":"control_request","request_id":"req_perm","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/a.txt","content":"hello"}}}"#
        let decoded = try ClaudeControlProtocol.decodePermissionRequest(line)
        let request = try #require(decoded)
        #expect(request.requestID == "req_perm")
        #expect(request.toolName == "Write")
        #expect(request.inputJSON.contains("file_path"))
        #expect(request.inputJSON.contains("/tmp/a.txt"))
    }

    @Test("other control requests are not treated as permission prompts")
    func ignoresOtherControlRequests() throws {
        let line = #"{"type":"control_request","request_id":"req_usage","request":{"subtype":"get_context_usage"}}"#
        #expect(try ClaudeControlProtocol.decodePermissionRequest(line) == nil)
    }

    @Test("permission allow response uses Claude control response envelope")
    func permissionAllowEncoding() throws {
        let line = try ClaudeControlProtocol.encodePermissionResponse(
            requestID: "req_allow",
            decision: .allow(updatedInputJSON: #"{"file_path":"/tmp/b.txt"}"#)
        )
        let data = try #require(line.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "control_response")

        let outer = try #require(json["response"] as? [String: Any])
        #expect(outer["request_id"] as? String == "req_allow")
        #expect(outer["subtype"] as? String == "success")

        let response = try #require(outer["response"] as? [String: Any])
        #expect(response["behavior"] as? String == "allow")
        let updatedInput = try #require(response["updatedInput"] as? [String: Any])
        #expect(updatedInput["file_path"] as? String == "/tmp/b.txt")
    }

    @Test("permission deny response includes user-facing reason")
    func permissionDenyEncoding() throws {
        let line = try ClaudeControlProtocol.encodePermissionResponse(
            requestID: "req_deny",
            decision: .deny(message: "Not approved")
        )
        let data = try #require(line.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outer = try #require(json["response"] as? [String: Any])
        let response = try #require(outer["response"] as? [String: Any])
        #expect(response["behavior"] as? String == "deny")
        #expect(response["message"] as? String == "Not approved")
    }
}
