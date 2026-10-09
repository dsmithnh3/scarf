import Foundation
import Testing
import ScarfCore
@testable import scarf

@Suite("Agent provider installation diagnostics")
struct AgentProviderDiagnosticsTests {
    @Test("status snapshot carries executable path alongside installation status")
    func snapshotIncludesExecutablePath() {
        let available = AgentBackendStatusSnapshot(
            id: .claudeCode,
            displayName: "Claude Code",
            executablePath: "/opt/homebrew/bin/claude",
            status: .available(version: "2.1.0"),
            authHealth: .notProbed
        )
        #expect(available.executablePath == "/opt/homebrew/bin/claude")
        #expect(available.status == .available(version: "2.1.0"))
        #expect(available.authHealth == .notProbed)

        let missing = AgentBackendStatusSnapshot(
            id: .claudeCode,
            displayName: "Claude Code",
            executablePath: nil,
            status: .notInstalled,
            authHealth: .notProbed
        )
        #expect(missing.executablePath == nil)
        #expect(missing.status == .notInstalled)
        #expect(missing.authHealth == .notProbed)
    }

    @Test("Claude diagnostics expose resolved path when installed")
    func claudeInstalledPathAndVersion() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { "/custom/bin/claude" },
            installationProbe: { executable in
                #expect(executable == "/custom/bin/claude")
                return .available(version: "2.1-test")
            },
            environmentProvider: { [:] }
        )
        #expect(backend.resolvedExecutablePath() == "/custom/bin/claude")
        #expect(await backend.installationStatus() == .available(version: "2.1-test"))
    }

    @Test("Claude diagnostics report nil path and notInstalled when missing")
    func claudeNotInstalledPath() async {
        let backend = ClaudeCodeBackend(
            executableResolver: { nil },
            installationProbe: { _ in .available(version: "should-not-run") },
            environmentProvider: { [:] }
        )
        #expect(backend.resolvedExecutablePath() == nil)
        #expect(await backend.installationStatus() == .notInstalled)
    }

    @Test("Hermes diagnostics report nil path and notInstalled when no executable is found")
    func hermesNotInstalledPath() async {
        let backend = HermesBackend(
            context: .local,
            executableResolver: { nil },
            installationProbe: nil,
            credentialProbe: { false }
        )
        #expect(backend.resolvedExecutablePath() == nil)
        #expect(await backend.installationStatus() == .notInstalled)
        #expect(await backend.authHealth() == .noCredentialsDetected)
    }

    @Test("Hermes diagnostics expose resolved path and version when installed")
    func hermesInstalledPathAndVersion() async {
        let backend = HermesBackend(
            context: .local,
            executableResolver: { "/opt/homebrew/bin/hermes" },
            installationProbe: { .available(version: "3.5-test") },
            credentialProbe: { true }
        )
        #expect(backend.resolvedExecutablePath() == "/opt/homebrew/bin/hermes")
        #expect(await backend.installationStatus() == .available(version: "3.5-test"))
    }

    @Test("Hermes auth health reports credentials detected from verified probe")
    func hermesAuthHealthCredentialsDetected() async {
        let backend = HermesBackend(
            context: .local,
            executableResolver: { "/opt/homebrew/bin/hermes" },
            installationProbe: { .available(version: "3.5-test") },
            credentialProbe: { true }
        )
        #expect(await backend.authHealth() == .credentialsDetected)
    }

    @Test("Hermes auth health reports missing credentials from verified probe")
    func hermesAuthHealthMissingCredentials() async {
        let backend = HermesBackend(
            context: .local,
            executableResolver: { "/opt/homebrew/bin/hermes" },
            installationProbe: { .available(version: "3.5-test") },
            credentialProbe: { false }
        )
        #expect(await backend.authHealth() == .noCredentialsDetected)
    }

    @Test("Claude auth health maps claude auth status loggedIn and strips harvested API keys")
    func claudeAuthHealthFromAuthStatus() async {
        let loggedIn = ClaudeCodeBackend(
            executableResolver: { "/custom/bin/claude" },
            installationProbe: { _ in .available(version: "2.1-test") },
            environmentProvider: {
                [
                    "PATH": "/usr/bin",
                    "ANTHROPIC_API_KEY": "stale-gui-key",
                    "ANTHROPIC_AUTH_TOKEN": "stale-token",
                    "CLAUDECODE": "1",
                    "CLAUDE_CODE_ENTRYPOINT": "cli",
                ]
            },
            authStatusProbe: { executable, environment in
                #expect(executable == "/custom/bin/claude")
                #expect(environment["PATH"] == "/usr/bin")
                #expect(environment["ANTHROPIC_API_KEY"] == nil)
                #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
                #expect(environment["CLAUDECODE"] == nil)
                #expect(environment["CLAUDE_CODE_ENTRYPOINT"] == nil)
                return ClaudeAuthStatus.health(parsing: #"{"loggedIn":true,"authMethod":"claude.ai"}"#)
            }
        )
        #expect(await loggedIn.authHealth() == .credentialsDetected)

        let loggedOut = ClaudeCodeBackend(
            executableResolver: { "/custom/bin/claude" },
            installationProbe: { _ in .available(version: "2.1-test") },
            environmentProvider: { [:] },
            authStatusProbe: { _, _ in
                ClaudeAuthStatus.health(parsing: #"{"loggedIn":false}"#)
            }
        )
        #expect(await loggedOut.authHealth() == .noCredentialsDetected)
    }

    @Test("Claude auth health stays notProbed when the CLI is missing or the status JSON is unusable")
    func claudeAuthHealthNotProbedWithoutAProbe() async {
        var probed = false
        let missing = ClaudeCodeBackend(
            executableResolver: { nil },
            installationProbe: { _ in .available(version: "should-not-run") },
            environmentProvider: { [:] },
            authStatusProbe: { _, _ in
                probed = true
                return .credentialsDetected
            }
        )
        #expect(await missing.authHealth() == .notProbed)
        #expect(probed == false)

        #expect(ClaudeAuthStatus.health(parsing: "not json") == .notProbed)
        #expect(ClaudeAuthStatus.health(parsing: #"{"authMethod":"claude.ai"}"#) == .notProbed)
    }

    @Test("Hermes local resolver returns nil when no candidate is executable")
    func hermesResolverMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("bin/hermes").path
        let resolved = HermesPathSet.resolveInstalledBinary(
            candidates: [missing],
            fileManager: .default
        )
        #expect(resolved == nil)
    }

    @Test("Hermes local resolver returns the first executable candidate")
    func hermesResolverFindsExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("bin/hermes")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )

        let resolved = HermesPathSet.resolveInstalledBinary(
            candidates: [binary.path, root.appendingPathComponent("other/hermes").path],
            fileManager: .default
        )
        #expect(resolved == binary.path)
    }

    @Test("status detail includes version and executable path when both are known")
    func statusDetailIncludesPathAndVersion() {
        let snapshot = AgentBackendStatusSnapshot(
            id: .claudeCode,
            displayName: "Claude Code",
            executablePath: "/opt/homebrew/bin/claude",
            status: .available(version: "2.1.0"),
            authHealth: .notProbed
        )
        #expect(
            AgentBackendStatusFormatting.detailText(for: snapshot)
                == "2.1.0 · /opt/homebrew/bin/claude"
        )
    }

    @Test("status detail for notInstalled does not invent an executable path")
    func statusDetailNotInstalled() {
        let snapshot = AgentBackendStatusSnapshot(
            id: .claudeCode,
            displayName: "Claude Code",
            executablePath: nil,
            status: .notInstalled,
            authHealth: .notProbed
        )
        #expect(
            AgentBackendStatusFormatting.detailText(for: snapshot)
                == "Claude Code executable was not found"
        )
    }

    @Test("status detail appends Hermes credential health when probed")
    func statusDetailIncludesHermesAuthHealth() {
        let withCreds = AgentBackendStatusSnapshot(
            id: .hermes,
            displayName: "Hermes",
            executablePath: "/opt/homebrew/bin/hermes",
            status: .available(version: "3.5"),
            authHealth: .credentialsDetected
        )
        #expect(
            AgentBackendStatusFormatting.detailText(for: withCreds)
                == "3.5 · /opt/homebrew/bin/hermes · AI credentials detected"
        )

        let missingCreds = AgentBackendStatusSnapshot(
            id: .hermes,
            displayName: "Hermes",
            executablePath: "/opt/homebrew/bin/hermes",
            status: .available(version: "3.5"),
            authHealth: .noCredentialsDetected
        )
        #expect(
            AgentBackendStatusFormatting.detailText(for: missingCreds)
                == "3.5 · /opt/homebrew/bin/hermes · No AI credentials detected"
        )
    }

    @Test("Claude status detail does not invent auth claims when not probed")
    func statusDetailClaudeAuthSilent() {
        let snapshot = AgentBackendStatusSnapshot(
            id: .claudeCode,
            displayName: "Claude Code",
            executablePath: "/opt/homebrew/bin/claude",
            status: .available(version: "2.1.0"),
            authHealth: .notProbed
        )
        #expect(
            AgentBackendStatusFormatting.detailText(for: snapshot)
                == "2.1.0 · /opt/homebrew/bin/claude"
        )
        #expect(
            !AgentBackendStatusFormatting.detailText(for: snapshot)
                .localizedCaseInsensitiveContains("credential")
        )
        #expect(
            !AgentBackendStatusFormatting.detailText(for: snapshot)
                .localizedCaseInsensitiveContains("oauth")
        )
    }

    @Test("Claude models() stays empty until initialize returns a models array")
    func claudeModelsDiscoveryBlocked() async throws {
        let backend = ClaudeCodeBackend(
            executableResolver: { "/custom/bin/claude" },
            installationProbe: { _ in .available(version: "2.1-test") },
            environmentProvider: { [:] }
        )
        #expect(try await backend.models().isEmpty)
    }

    @Test("Hermes models() stays empty when no configured provider is resolved")
    func hermesModelsEmptyWithoutConfiguredProvider() async throws {
        let backend = HermesBackend(
            context: .local,
            executableResolver: { "/opt/homebrew/bin/hermes" },
            installationProbe: { .available(version: "3.5-test") },
            credentialProbe: { true },
            configuredProviderResolver: { nil }
        )
        #expect(try await backend.models().isEmpty)
    }
}
