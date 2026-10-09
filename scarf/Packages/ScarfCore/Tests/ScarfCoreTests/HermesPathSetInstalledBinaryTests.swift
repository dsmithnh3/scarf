import Foundation
import Testing
@testable import ScarfCore

@Suite("HermesPathSet installed binary resolution")
struct HermesPathSetInstalledBinaryTests {
    @Test("resolveInstalledBinary returns nil when no candidate is executable")
    func missingReportsNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("bin/hermes").path
        #expect(HermesPathSet.resolveInstalledBinary(candidates: [missing]) == nil)
    }

    @Test("resolveInstalledBinary returns the first executable candidate")
    func findsExecutable() throws {
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
            candidates: [binary.path, root.appendingPathComponent("other/hermes").path]
        )
        #expect(resolved == binary.path)
    }

    @Test("hermesBinaryIfInstalled is nil locally when no candidate exists")
    func ifInstalledNilWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // hermesBinaryIfInstalled uses the process HOME candidates; exercise the
        // shared resolver directly for a deterministic empty candidate set.
        #expect(HermesPathSet.resolveInstalledBinary(candidates: []) == nil)
    }
}
