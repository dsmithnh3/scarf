import Foundation
import Testing
@testable import ScarfCore

@Suite("Agent permission presenter")
struct AgentPermissionPresenterTests {

    private func hermesRequest(
        id: String = "42",
        title: String = "Write /tmp/demo.txt",
        detail: String? = "edit",
        options: [AgentPermissionOption] = [
            AgentPermissionOption(id: "allow_once", title: "Allow once"),
            AgentPermissionOption(id: "deny", title: "Deny"),
        ]
    ) -> AgentPermissionRequest {
        AgentPermissionRequest(id: id, title: title, detail: detail, options: options)
    }

    @Test("empty coordinator yields no presentation")
    func emptyCoordinatorHasNoPresentation() {
        let coordinator = AgentPermissionCoordinator()
        #expect(AgentPermissionPresenter.presentation(from: coordinator) == nil)
    }

    @Test("Hermes pending head becomes a card presentation with wire request")
    func hermesPendingHeadBecomesPresentation() {
        var coordinator = AgentPermissionCoordinator()
        let request = hermesRequest()
        coordinator.record(.hermes(from: request, sessionID: "sess-1"))

        let presentation = AgentPermissionPresenter.presentation(from: coordinator)
        #expect(presentation != nil)
        #expect(presentation?.id == "42")
        #expect(presentation?.title == "Write /tmp/demo.txt")
        #expect(presentation?.detail == "edit")
        #expect(presentation?.options.map(\.id) == ["allow_once", "deny"])
        #expect(presentation?.pendingCount == 1)
        #expect(presentation?.backendID == .hermes)
        #expect(presentation?.request == request)
        #expect(Int(presentation!.request.id) == 42)
    }

    @Test("FIFO head is presented; pendingCount includes the queue")
    func fifoHeadAndPendingCount() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(.hermes(from: hermesRequest(id: "10", title: "First"), sessionID: "s"))
        coordinator.record(.hermes(from: hermesRequest(id: "11", title: "Second"), sessionID: "s"))

        let presentation = AgentPermissionPresenter.presentation(from: coordinator)
        #expect(presentation?.id == "10")
        #expect(presentation?.title == "First")
        #expect(presentation?.pendingCount == 2)

        _ = coordinator.answer(id: "10", optionID: "allow_once")
        let next = AgentPermissionPresenter.presentation(from: coordinator)
        #expect(next?.id == "11")
        #expect(next?.pendingCount == 1)
    }

    @Test("conversation state presentation mirrors coordinator")
    func conversationStatePresentationMirrorsCoordinator() {
        var state = AgentConversationState()
        let session = AgentSession(
            id: "sess-h",
            backendID: .hermes,
            workingDirectory: nil
        )
        let request = hermesRequest(id: "99")
        state.apply(.sessionStarted(session))
        state.apply(.permissionRequested(request))

        let presentation = AgentPermissionPresenter.presentation(from: state)
        #expect(presentation?.request == request)
        #expect(presentation?.backendID == .hermes)
        #expect(state.permissionRequest == request)
    }

    @Test("answered/cancelled queue yields no presentation")
    func resolvedQueueHasNoPresentation() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(.hermes(from: hermesRequest(), sessionID: "s"))
        _ = coordinator.cancel(id: "42")
        #expect(AgentPermissionPresenter.presentation(from: coordinator) == nil)
    }

    @Test("generic non-Hermes record still surfaces without inventing options")
    func genericRecordSurfacesCoordinatorFieldsOnly() {
        var coordinator = AgentPermissionCoordinator()
        let options = [
            AgentPermissionOption(id: "allow", title: "Allow"),
            AgentPermissionOption(id: "deny", title: "Deny"),
        ]
        coordinator.record(
            AgentPermissionRecord(
                id: "req_1",
                backendID: .claudeCode,
                sessionID: "sess-c",
                category: "Bash",
                description: "Run ls",
                options: options
            )
        )

        let presentation = AgentPermissionPresenter.presentation(from: coordinator)
        #expect(presentation?.backendID == .claudeCode)
        #expect(presentation?.title == "Run ls")
        #expect(presentation?.detail == "Bash")
        #expect(presentation?.options == options)
        #expect(presentation?.request.options == options)
    }
}
