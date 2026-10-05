import Foundation
import Observation
import ScarfCore

/// Thin macOS observation adapter around `AgentConversationController`.
///
/// Backend/session behavior stays in ScarfCore. This type only mirrors state
/// snapshots onto the main actor and delegates user actions to the controller.
/// The existing Hermes `ChatViewModel` remains unchanged and authoritative for
/// the production Hermes chat path during the migration.
@MainActor
@Observable
final class AgentChatViewModel {
    private let controller: AgentConversationController
    private let backendID: AgentID
    private let workingDirectory: URL

    private(set) var state = AgentConversationState()
    private(set) var isStarted = false
    private(set) var startupError: String?

    @ObservationIgnored
    private var stateTask: Task<Void, Never>?

    init(
        controller: AgentConversationController,
        backendID: AgentID,
        workingDirectory: URL
    ) {
        self.controller = controller
        self.backendID = backendID
        self.workingDirectory = workingDirectory
        observeState()
    }

    deinit {
        stateTask?.cancel()
    }

    func start() async {
        guard !isStarted else { return }
        startupError = nil

        do {
            _ = try await controller.startOrRestorePersistedSession(
                backendID: backendID,
                configuration: AgentSessionConfiguration(
                    workingDirectory: workingDirectory
                )
            )
            isStarted = true
        } catch {
            startupError = String(describing: error)
        }
    }

    func send(_ content: String) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await controller.send(trimmed)
    }

    func cancel() async throws {
        try await controller.cancel()
    }

    func close() async {
        guard isStarted else { return }
        do {
            try await controller.close()
        } catch {
            // Teardown is best effort. The backend process/channel owns its own
            // bounded shutdown path, and leaving Chat must not trap the user on
            // the surface because a close notification failed.
        }
        isStarted = false
    }

    func respond(to request: AgentPermissionRequest, optionID: String) async throws {
        try await controller.respond(to: request, optionID: optionID)
    }

    func cancelPermission(_ request: AgentPermissionRequest) async throws {
        try await controller.cancelPermission(request)
    }

    private func observeState() {
        let stream = controller.stateUpdates
        stateTask = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                self?.state = snapshot
            }
        }
    }
}
