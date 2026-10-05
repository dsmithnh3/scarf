import AppIntents
import Foundation

/// Opens the frontmost window's selected project on the Board panel.
/// The cockpit applies the request only when that host has Kanban.
/// No entity schema: this floor does not ship App Intents entities.
struct OpenTaskBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open the task board"
    static var description = IntentDescription(
        "Opens the selected project in the frontmost window on its task board."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let coordinator = AppCoordinator.frontmost {
            coordinator.requestOpenBoard()
        } else {
            // The shortcut launched the app and the window has not
            // published a coordinator yet. The first active window
            // consumes this.
            AppCoordinator.pendingOpenBoard = true
        }
        return .result()
    }
}

struct OpenTaskBoardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTaskBoardIntent(),
            phrases: [
                "Open the task board in \(.applicationName)",
            ],
            shortTitle: "Open the task board",
            systemImageName: "rectangle.split.3x1"
        )
    }
}
