import Foundation
import Testing
@testable import ScarfCore

/// Phase 4 permission model slice — backend-neutral coordinator state machine.
///
/// Preserves Hermes ACP permission identity (`AgentPermissionRequest` numeric
/// ids + options) and queue semantics from Rich Chat, without advertising
/// Claude `.permissions` or inventing a Claude round trip.
@Suite("Agent permission coordinator")
struct AgentPermissionCoordinatorTests {

    private func hermesRequest(
        id: String = "42",
        title: String = "run: ls",
        kind: String = "execute",
        options: [AgentPermissionOption] = [
            AgentPermissionOption(id: "allow_once", title: "Allow once"),
            AgentPermissionOption(id: "deny", title: "Deny"),
        ]
    ) -> AgentPermissionRequest {
        AgentPermissionRequest(id: id, title: title, detail: kind, options: options)
    }

    // MARK: - Record shape

    @Test("permission record carries identity category description details options scope and status")
    func recordCarriesRequiredFields() {
        let record = AgentPermissionRecord(
            id: "7",
            backendID: .hermes,
            sessionID: "sess-1",
            category: "execute",
            description: "run: curl example.com",
            details: ["toolCallId": "perm-check-3", "command": "curl example.com"],
            options: [
                AgentPermissionOption(id: "allow_once", title: "Allow once"),
                AgentPermissionOption(id: "deny", title: "Deny"),
            ],
            scope: .once,
            status: .pending
        )

        #expect(record.id == "7")
        #expect(record.backendID == .hermes)
        #expect(record.sessionID == "sess-1")
        #expect(record.category == "execute")
        #expect(record.description == "run: curl example.com")
        #expect(record.details["toolCallId"] == "perm-check-3")
        #expect(record.options.map(\.id) == ["allow_once", "deny"])
        #expect(record.scope == .once)
        #expect(record.status == .pending)
        #expect(record.selectedOptionID == nil)
    }

    // MARK: - Hermes preservation

    @Test("Hermes AgentPermissionRequest maps into coordinator record and back for respond/cancel")
    func hermesRequestRoundTripsForRespondCancel() {
        let request = hermesRequest()
        let record = AgentPermissionRecord.hermes(
            from: request,
            sessionID: "hermes-session",
            toolCallID: "perm-check-9"
        )

        #expect(record.id == "42")
        #expect(record.backendID == .hermes)
        #expect(record.sessionID == "hermes-session")
        #expect(record.category == "execute")
        #expect(record.description == "run: ls")
        #expect(record.details["toolCallId"] == "perm-check-9")
        #expect(record.options.map(\.id) == ["allow_once", "deny"])
        #expect(record.status == .pending)

        let wire = record.asAgentPermissionRequest
        #expect(wire == request)
        #expect(Int(wire.id) == 42) // HermesBackend requires Int(request.id)
    }

    @Test("Hermes capabilities include permissions; Claude default capabilities do not")
    func capabilityGatePreservesHermesOmitsClaude() {
        let hermesCaps = AgentSlashHintPresenter.defaultCapabilities(for: .hermes)
        let claudeCaps = AgentSlashHintPresenter.defaultCapabilities(for: .claudeCode)

        #expect(AgentPermissionCoordinator.supportsPermissions(hermesCaps))
        #expect(!AgentPermissionCoordinator.supportsPermissions(claudeCaps))
        #expect(hermesCaps.contains(.permissions))
        #expect(!claudeCaps.contains(.permissions))
    }

    // MARK: - Queue / state machine

    @Test("second request queues behind the first; answer advances FIFO head")
    func secondRequestQueuesBehindFirst() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "1", title: "first"), sessionID: "s")
        )
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "2", title: "second"), sessionID: "s")
        )

        #expect(coordinator.pending.map(\.id) == ["1", "2"])
        #expect(coordinator.presented?.id == "1")
        #expect(coordinator.presented?.description == "first")

        #expect(coordinator.answer(id: "1", optionID: "allow_once"))
        #expect(coordinator.pending.map(\.id) == ["2"])
        #expect(coordinator.presented?.id == "2")
        #expect(coordinator.records.first { $0.id == "1" }?.status == .answered)
        #expect(coordinator.records.first { $0.id == "1" }?.selectedOptionID == "allow_once")
    }

    @Test("answer and cancel are id-keyed not positional")
    func answerAndCancelAreIdKeyed() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "10", title: "first"), sessionID: "s")
        )
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "11", title: "second"), sessionID: "s")
        )

        #expect(coordinator.answer(id: "11", optionID: "deny"))
        #expect(coordinator.pending.map(\.id) == ["10"])
        #expect(coordinator.records.first { $0.id == "11" }?.status == .answered)
        #expect(coordinator.records.first { $0.id == "11" }?.selectedOptionID == "deny")

        #expect(coordinator.cancel(id: "10"))
        #expect(coordinator.pending.isEmpty)
        #expect(coordinator.records.first { $0.id == "10" }?.status == .cancelled)
        #expect(coordinator.records.first { $0.id == "10" }?.selectedOptionID == nil)
    }

    @Test("duplicate pending id refreshes in place rather than double-queueing")
    func duplicatePendingIdRefreshesInPlace() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "7", title: "original"), sessionID: "s")
        )
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "7", title: "refreshed"), sessionID: "s")
        )

        #expect(coordinator.pending.count == 1)
        #expect(coordinator.presented?.description == "refreshed")
        #expect(coordinator.records.count == 1)
    }

    @Test("double answer or cancel of the same id is a no-op")
    func doubleAnswerOrCancelIsNoOp() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "1", title: "first"), sessionID: "s")
        )
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "2", title: "second"), sessionID: "s")
        )

        #expect(coordinator.answer(id: "1", optionID: "allow_once"))
        #expect(!coordinator.answer(id: "1", optionID: "deny"))
        #expect(coordinator.presented?.id == "2")
        #expect(coordinator.pending.count == 1)

        #expect(coordinator.cancel(id: "2"))
        #expect(!coordinator.cancel(id: "2"))
        #expect(coordinator.pending.isEmpty)
    }

    @Test("answer rejects unknown option ids without mutating status")
    func answerRejectsUnknownOptionID() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "1"), sessionID: "s")
        )

        #expect(!coordinator.answer(id: "1", optionID: "not-a-real-option"))
        #expect(coordinator.presented?.status == .pending)
        #expect(coordinator.presented?.selectedOptionID == nil)
    }

    @Test("clearPending drops only pending rows and leaves answered history")
    func clearPendingKeepsAnsweredHistory() {
        var coordinator = AgentPermissionCoordinator()
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "1", title: "done"), sessionID: "s")
        )
        coordinator.record(
            AgentPermissionRecord.hermes(from: hermesRequest(id: "2", title: "open"), sessionID: "s")
        )
        #expect(coordinator.answer(id: "1", optionID: "deny"))

        coordinator.clearPending()
        #expect(coordinator.pending.isEmpty)
        #expect(coordinator.records.map(\.id) == ["1"])
        #expect(coordinator.records[0].status == .answered)
    }

    // MARK: - Claude guardrails

    @Test("coordinator can record a Claude-shaped pending row without advertising permissions capability")
    func canRecordClaudeShapedRowWithoutAdvertisingCapability() {
        // Model may track future Claude control requests; capability stays false
        // until a verified round trip exists (ClaudeCodeBackend still throws).
        let record = AgentPermissionRecord(
            id: "scarf_req_abc",
            backendID: .claudeCode,
            sessionID: "claude-sess",
            category: "can_use_tool",
            description: "Bash",
            details: ["inputJSON": #"{"command":"ls"}"#],
            options: [
                AgentPermissionOption(id: "allow", title: "Allow"),
                AgentPermissionOption(id: "deny", title: "Deny"),
            ],
            scope: .once,
            status: .pending
        )

        var coordinator = AgentPermissionCoordinator()
        coordinator.record(record)

        #expect(coordinator.presented?.backendID == .claudeCode)
        #expect(coordinator.presented?.category == "can_use_tool")
        #expect(!AgentPermissionCoordinator.supportsPermissions(
            AgentSlashHintPresenter.defaultCapabilities(for: .claudeCode)
        ))
    }
}
