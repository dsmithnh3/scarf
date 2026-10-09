import Foundation

enum ClaudeExecutableResolver {
    static let standardCandidates = [
        ".local/bin/claude",
        ".claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    static func resolve(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        standardCandidates: [String] = ClaudeExecutableResolver.standardCandidates,
        fileManager: FileManager = .default
    ) -> String? {
        var candidates: [String] = []

        if let explicitPath, !explicitPath.isEmpty {
            candidates.append(explicitPath)
        }
        if let override = environment["CLAUDE_CODE_PATH"], !override.isEmpty {
            candidates.append(override)
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("claude").path
            }
        }
        candidates += standardCandidates.map { candidate in
            candidate.hasPrefix("/")
                ? candidate
                : homeDirectory.appendingPathComponent(candidate).path
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard fileManager.isExecutableFile(atPath: candidate) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            return candidate
        }
        return nil
    }
}
