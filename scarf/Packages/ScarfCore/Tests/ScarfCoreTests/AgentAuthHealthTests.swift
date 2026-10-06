import Testing
@testable import ScarfCore

@Suite("Agent auth health diagnostics")
struct AgentAuthHealthTests {
    @Test("detail suffix is silent when auth was not probed")
    func notProbedHasNoSuffix() {
        #expect(AgentAuthHealthFormatting.detailSuffix(for: .notProbed) == nil)
        #expect(
            AgentAuthHealthFormatting.appendingDetailSuffix(
                to: "2.1.0 · /opt/bin/claude",
                health: .notProbed
            ) == "2.1.0 · /opt/bin/claude"
        )
    }

    @Test("credentials detected appends a truthful suffix")
    func credentialsDetectedSuffix() {
        #expect(
            AgentAuthHealthFormatting.detailSuffix(for: .credentialsDetected)
                == "AI credentials detected"
        )
        #expect(
            AgentAuthHealthFormatting.appendingDetailSuffix(
                to: "3.5 · /opt/homebrew/bin/hermes",
                health: .credentialsDetected
            ) == "3.5 · /opt/homebrew/bin/hermes · AI credentials detected"
        )
    }

    @Test("missing credentials appends a truthful suffix")
    func noCredentialsSuffix() {
        #expect(
            AgentAuthHealthFormatting.detailSuffix(for: .noCredentialsDetected)
                == "No AI credentials detected"
        )
        #expect(
            AgentAuthHealthFormatting.appendingDetailSuffix(
                to: "Runtime executable was not found",
                health: .noCredentialsDetected
            ) == "Runtime executable was not found · No AI credentials detected"
        )
    }

    @Test("empty base detail uses the auth suffix alone")
    func emptyBaseUsesSuffixAlone() {
        #expect(
            AgentAuthHealthFormatting.appendingDetailSuffix(
                to: "",
                health: .credentialsDetected
            ) == "AI credentials detected"
        )
    }
}
