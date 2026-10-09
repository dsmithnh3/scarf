import Foundation

/// Environment handed to a Claude Code child process.
///
/// Starts from whatever the caller harvested (Scarf uses
/// `HermesFileService.enrichedEnvironment()` so PATH matches a login shell)
/// and then removes credentials and nested-session markers that would make
/// the CLI ignore the user's Claude login.
enum ClaudeProcessEnvironment {
    /// `ANTHROPIC_API_KEY` in the environment takes precedence over Claude
    /// subscription / profile login (Claude Code 2.1.289). Hermes still needs
    /// the harvested key; only the Claude child drops it.
    static let strippedCredentialKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    static func sanitized(_ environment: [String: String]) -> [String: String] {
        var env = environment
        for key in strippedCredentialKeys {
            env.removeValue(forKey: key)
        }
        env.removeValue(forKey: "CLAUDECODE")
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_BASH_") {
            env.removeValue(forKey: key)
        }
        return env
    }
}
