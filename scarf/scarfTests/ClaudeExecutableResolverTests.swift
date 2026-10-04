import Foundation
import Testing
@testable import scarf

@Suite("Claude Code executable resolver")
struct ClaudeExecutableResolverTests {
    @Test("explicit executable path has highest priority")
    func explicitPathWins() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let explicit = root.appendingPathComponent("explicit-claude")
        try makeExecutable(at: explicit)
        let pathClaude = root.appendingPathComponent("bin/claude")
        try makeExecutable(at: pathClaude)

        let resolved = ClaudeExecutableResolver.resolve(
            explicitPath: explicit.path,
            environment: ["PATH": pathClaude.deletingLastPathComponent().path],
            homeDirectory: root
        )
        #expect(resolved == explicit.path)
    }

    @Test("CLAUDE_CODE_PATH precedes PATH lookup")
    func environmentOverride() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let override = root.appendingPathComponent("override")
        try makeExecutable(at: override)
        let pathClaude = root.appendingPathComponent("bin/claude")
        try makeExecutable(at: pathClaude)

        let resolved = ClaudeExecutableResolver.resolve(
            environment: [
                "CLAUDE_CODE_PATH": override.path,
                "PATH": pathClaude.deletingLastPathComponent().path,
            ],
            homeDirectory: root
        )
        #expect(resolved == override.path)
    }

    @Test("PATH lookup finds executable Claude binary")
    func pathLookup() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("custom/bin/claude")
        try makeExecutable(at: binary)

        let resolved = ClaudeExecutableResolver.resolve(
            environment: ["PATH": binary.deletingLastPathComponent().path],
            homeDirectory: root
        )
        #expect(resolved == binary.path)
    }

    @Test("non-executable candidates are rejected")
    func rejectsNonExecutable() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)

        let resolved = ClaudeExecutableResolver.resolve(
            environment: ["PATH": binary.deletingLastPathComponent().path],
            homeDirectory: root,
            standardCandidates: []
        )
        #expect(resolved == nil)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
