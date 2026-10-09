import Foundation

/// Stable identifier for an agent runtime supported by Scarf.
///
/// The raw-value representation is intentionally open so future backends can
/// participate without changing the shared domain model.
public struct AgentID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    public static let hermes = AgentID("hermes")
    public static let claudeCode = AgentID("claude-code")
}
