import Foundation
import ScarfCore

struct ClaudeProcessStreams: Sendable {
    let incoming: AsyncThrowingStream<String, Error>
    let stderr: AsyncThrowingStream<String, Error>
}

actor ClaudeProcessManager {
    typealias ChannelFactory = @Sendable (
        _ command: ClaudeProcessCommand,
        _ environment: [String: String]
    ) async throws -> any ACPChannel
    typealias EnvironmentProvider = @Sendable () -> [String: String]

    private let channelFactory: ChannelFactory
    private let environmentProvider: EnvironmentProvider
    private var channel: (any ACPChannel)?

    init(
        channelFactory: @escaping ChannelFactory = ClaudeProcessManager.defaultChannelFactory,
        environmentProvider: @escaping EnvironmentProvider = { ProcessInfo.processInfo.environment }
    ) {
        self.channelFactory = channelFactory
        self.environmentProvider = environmentProvider
    }

    func start(command: ClaudeProcessCommand) async throws -> ClaudeProcessStreams {
        if let existing = channel {
            await existing.close()
            channel = nil
        }

        let launched = try await channelFactory(command, environmentProvider())
        channel = launched
        return ClaudeProcessStreams(incoming: launched.incoming, stderr: launched.stderr)
    }

    func sendUserMessage(_ text: String) async throws {
        let record = try ClaudeProcessConfiguration.userMessageJSON(text)
        try await sendRecord(record)
    }

    @discardableResult
    func sendInterrupt() async throws -> String {
        let request = ClaudeControlRequest.interrupt()
        try await sendRecord(ClaudeControlProtocol.encode(request))
        return request.requestID
    }

    func sendRecord(_ record: String) async throws {
        guard let channel else { throw ClaudeProcessManagerError.notRunning }
        try await channel.send(record)
    }

    func close() async {
        guard let channel else { return }
        self.channel = nil
        await channel.close()
    }

    func diagnosticID() async -> String? {
        guard let channel else { return nil }
        return await channel.diagnosticID
    }

    nonisolated private static func defaultChannelFactory(
        command: ClaudeProcessCommand,
        environment: [String: String]
    ) async throws -> any ACPChannel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = environment
        return try await ProcessACPChannel(process: process)
    }
}

enum ClaudeProcessManagerError: Error, Equatable {
    case notRunning
}
