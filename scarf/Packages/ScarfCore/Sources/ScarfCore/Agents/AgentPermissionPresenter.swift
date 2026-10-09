import Foundation

/// Snapshot a Scarf-native permission card can render from conversation state.
///
/// Built from ``AgentPermissionCoordinator.presented`` so the multi-agent UI
/// stays aligned with respond/cancel wiring. Pure ScarfCore — no SwiftUI / CLUI.
public struct AgentPermissionPresentation: Equatable, Sendable, Identifiable {
    public var id: String { request.id }
    /// Wire shape for `AgentBackend.respond` / `cancelPermission`.
    public var request: AgentPermissionRequest
    public var title: String
    public var detail: String?
    public var options: [AgentPermissionOption]
    /// How many permissions are waiting (including the presented head).
    public var pendingCount: Int
    public var backendID: AgentID

    public init(
        request: AgentPermissionRequest,
        title: String,
        detail: String?,
        options: [AgentPermissionOption],
        pendingCount: Int,
        backendID: AgentID
    ) {
        self.request = request
        self.title = title
        self.detail = detail
        self.options = options
        self.pendingCount = pendingCount
        self.backendID = backendID
    }
}

/// ViewModel-facing presenter that turns coordinator / conversation state into
/// a Scarf-native permission card snapshot.
///
/// Does not invent options or Claude-specific chrome — only surfaces what the
/// coordinator already holds from `permissionRequested` events.
public enum AgentPermissionPresenter {
    /// Build presentation from the coordinator's FIFO head, if any.
    public static func presentation(
        from coordinator: AgentPermissionCoordinator
    ) -> AgentPermissionPresentation? {
        guard let presented = coordinator.presented else { return nil }
        let request = presented.asAgentPermissionRequest
        return AgentPermissionPresentation(
            request: request,
            title: presented.description,
            detail: presented.category.isEmpty ? nil : presented.category,
            options: presented.options,
            pendingCount: coordinator.pending.count,
            backendID: presented.backendID
        )
    }

    /// Convenience for conversation state snapshots (legacy `permissionRequest`
    /// stays in sync with the coordinator head).
    public static func presentation(
        from state: AgentConversationState
    ) -> AgentPermissionPresentation? {
        presentation(from: state.permissionCoordinator)
    }
}
