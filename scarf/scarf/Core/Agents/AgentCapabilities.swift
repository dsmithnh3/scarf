import Foundation

struct AgentCapabilities: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static let streaming       = AgentCapabilities(rawValue: 1 << 0)
    static let reasoning       = AgentCapabilities(rawValue: 1 << 1)
    static let toolCalls       = AgentCapabilities(rawValue: 1 << 2)
    static let permissions     = AgentCapabilities(rawValue: 1 << 3)
    static let sessions        = AgentCapabilities(rawValue: 1 << 4)
    static let resume          = AgentCapabilities(rawValue: 1 << 5)
    static let mcp             = AgentCapabilities(rawValue: 1 << 6)
    static let skills          = AgentCapabilities(rawValue: 1 << 7)
    static let hooks           = AgentCapabilities(rawValue: 1 << 8)
    static let subagents       = AgentCapabilities(rawValue: 1 << 9)
    static let usage           = AgentCapabilities(rawValue: 1 << 10)
    static let fileChanges     = AgentCapabilities(rawValue: 1 << 11)
    static let shellCommands   = AgentCapabilities(rawValue: 1 << 12)
    static let memory          = AgentCapabilities(rawValue: 1 << 13)
    static let cron            = AgentCapabilities(rawValue: 1 << 14)
    static let gateway         = AgentCapabilities(rawValue: 1 << 15)
    static let proxy           = AgentCapabilities(rawValue: 1 << 16)
    static let remoteExecution = AgentCapabilities(rawValue: 1 << 17)
}
