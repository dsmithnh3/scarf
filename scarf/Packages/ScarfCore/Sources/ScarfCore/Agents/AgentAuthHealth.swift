import Foundation

/// Truthful provider credential/auth health for diagnostics.
///
/// Only report detected / missing when a verified probe exists. Hermes uses
/// the env / `.env` / `auth.json` / config checks that feed chat's credential
/// banner. Claude Code uses `claude auth status` (`loggedIn` only). A failed
/// or absent probe stays ``notProbed``. Never invent OAuth UI or parse
/// Keychain / credential files.
public enum AgentAuthHealth: Equatable, Sendable {
    /// Verified probe found at least one AI credential the backend would accept.
    case credentialsDetected
    /// Verified probe found none.
    case noCredentialsDetected
    /// No verified auth probe for this backend yet.
    case notProbed
}

/// Shared copy for Settings / preference detail lines.
public enum AgentAuthHealthFormatting {
    /// Human-readable suffix, or `nil` when health must stay silent (not probed).
    public static func detailSuffix(for health: AgentAuthHealth) -> String? {
        switch health {
        case .credentialsDetected:
            return "AI credentials detected"
        case .noCredentialsDetected:
            return "No AI credentials detected"
        case .notProbed:
            return nil
        }
    }

    /// Append an auth suffix to an existing diagnostics detail line.
    public static func appendingDetailSuffix(
        to detail: String,
        health: AgentAuthHealth
    ) -> String {
        guard let suffix = detailSuffix(for: health) else { return detail }
        if detail.isEmpty { return suffix }
        return "\(detail) · \(suffix)"
    }
}
