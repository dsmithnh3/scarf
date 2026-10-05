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
            status: .available(version: "2.1.0")
        )
        #expect(available.executablePath == "/opt/homebrew/bin/claude")
        #expect(available.status == .available(version: "2.1.0"))

        let missing = AgentBackendStatusSnapshot(
            id: .claudeCode,
            displayName: "Claude Code",
            executablePath: nil,
            status: .notInstalled
        )
        #expect(missing.executablePath == nil)
        #expect(missing.status == .notInstalled)
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
            installationProbe: nil
        )
        #expect(backend.resolvedExecutablePath() == nil)
        #expect(await backend.installationStatus() == .notInstalled)
    }

    @Test("Hermes diagnostics expose resolved path and version when installed")
    func hermesInstalledPathAndVersion() async {
        let backend = HermesBackend(
            context: .local,
            executableResolver: { "/opt/homebrew/bin/hermes" },
            installationProbe: { .available(version: "3.5-test") }
        )
        #expect(backend.resolvedExecutablePath() == "/opt/homebrew/bin/hermes")
        #expect(await backend.installationStatus() == .available(version: "3.5-test"))
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
            status: .available(version: "2.1.0")
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
            status: .notInstalled
        )
        #expect(
            AgentBackendStatusFormatting.detailText(for: snapshot)
                == "Claude Code executable was not found"
        )
    }
}
