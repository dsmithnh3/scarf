import Foundation
import Testing
import ScarfCore
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
    }
}
