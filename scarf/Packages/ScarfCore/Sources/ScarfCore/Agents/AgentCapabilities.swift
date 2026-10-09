import Foundation

/// Feature set advertised by an agent backend.
public struct AgentCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let streaming       = AgentCapabilities(rawValue: 1 << 0)
    public static let reasoning       = AgentCapabilities(rawValue: 1 << 1)
    public static let toolCalls       = AgentCapabilities(rawValue: 1 << 2)
    public static let permissions     = AgentCapabilities(rawValue: 1 << 3)
    public static let sessions        = AgentCapabilities(rawValue: 1 << 4)
    public static let resume          = AgentCapabilities(rawValue: 1 << 5)
    public static let mcp             = AgentCapabilities(rawValue: 1 << 6)
    public static let skills          = AgentCapabilities(rawValue: 1 << 7)
    public static let hooks           = AgentCapabilities(rawValue: 1 << 8)
    public static let subagents       = AgentCapabilities(rawValue: 1 << 9)
    public static let usage           = AgentCapabilities(rawValue: 1 << 10)
    public static let fileChanges     = AgentCapabilities(rawValue: 1 << 11)
    public static let shellCommands   = AgentCapabilities(rawValue: 1 << 12)
    public static let memory          = AgentCapabilities(rawValue: 1 << 13)
    public static let cron            = AgentCapabilities(rawValue: 1 << 14)
    public static let gateway         = AgentCapabilities(rawValue: 1 << 15)
    public static let proxy           = AgentCapabilities(rawValue: 1 << 16)
    public static let remoteExecution = AgentCapabilities(rawValue: 1 << 17)
}
