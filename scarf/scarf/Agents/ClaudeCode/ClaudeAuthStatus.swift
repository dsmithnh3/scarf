import Foundation
import ScarfCore

/// `claude auth status` JSON → ``AgentAuthHealth``.
///
/// Reads only the `loggedIn` boolean. Does not open Keychain or a credentials file.
enum ClaudeAuthStatus {
    static func health(parsing json: String) -> AgentAuthHealth {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool
        else { return .notProbed }
        return loggedIn ? .credentialsDetected : .noCredentialsDetected
    }
}

enum ClaudeAuthStatusProbe {
    /// Run `claude auth status` with the caller's environment and a 10s cap.
    static func run(executable: String, environment: [String: String]) async -> AgentAuthHealth {
        await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["auth", "status"]
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                _ = stderr.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let health: AgentAuthHealth = process.terminationStatus == 0
                    ? ClaudeAuthStatus.health(parsing: text)
                    : .notProbed
                gate.resume(continuation, returning: health)
            }

            do {
                try process.run()
            } catch {
                gate.resume(continuation, returning: .notProbed)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

/// Resumes a continuation at most once.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(
        _ continuation: CheckedContinuation<AgentAuthHealth, Never>,
        returning health: AgentAuthHealth
    ) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: health)
        }
    }
}
