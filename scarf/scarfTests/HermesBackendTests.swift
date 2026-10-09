import Testing
import ScarfCore
@testable import scarf

@Suite("Hermes agent backend")
struct HermesBackendTests {
    @Test("Hermes advertises its existing first-class capabilities")
    func capabilities() {
        let backend = HermesBackend(context: .local, installationProbe: { .available(version: "test") })
        let capabilities = backend.capabilities

        #expect(backend.id == .hermes)
        #expect(backend.displayName == "Hermes")
        #expect(capabilities.contains(.streaming))
        #expect(capabilities.contains(.toolCalls))
        #expect(capabilities.contains(.permissions))
        #expect(capabilities.contains(.sessions))
        #expect(capabilities.contains(.resume))
        #expect(capabilities.contains(.mcp))
        #expect(capabilities.contains(.skills))
        #expect(capabilities.contains(.memory))
        #expect(capabilities.contains(.cron))
        #expect(capabilities.contains(.gateway))
        #expect(capabilities.contains(.proxy))
        #expect(capabilities.contains(.remoteExecution))
    }

    @Test("installation status delegates to injected probe")
    func installationProbe() async {
        let backend = HermesBackend(context: .local, installationProbe: { .available(version: "3.5-test") })
        #expect(await backend.installationStatus() == .available(version: "3.5-test"))
    }

    @Test("fetchConversationHistory returns loader results for Hermes sessions")
    func fetchConversationHistory() async throws {
        let expected = [
            AgentMessage(role: .user, content: "from state.db"),
            AgentMessage(role: .assistant, content: "mapped"),
        ]
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") },
            conversationHistoryLoader: { _, sessionID in
                #expect(sessionID == "sess-hermes-1")
                return expected
            }
        )
        let session = AgentSession(id: "sess-hermes-1", backendID: .hermes)
        let history = try await backend.fetchConversationHistory(for: session)
        #expect(history == expected)
    }

    @Test("models() maps the configured provider through the catalog loader")
    func modelsFromConfiguredProviderCatalog() async throws {
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") },
            configuredProviderResolver: { "openrouter" },
            catalogModelsLoader: { provider in
                #expect(provider == "openrouter")
                return [
                    AgentModel(id: "openrouter:anthropic/claude-sonnet-5", displayName: "Claude Sonnet 5"),
                    AgentModel(id: "openrouter:openai/gpt-5.5", displayName: "GPT-5.5"),
                ]
            },
            nousModelsLoader: {
                Issue.record("Nous loader must not run for a non-nous provider")
                return []
            }
        )

        let models = try await backend.models()
        #expect(models.map(\.id) == [
            "openrouter:anthropic/claude-sonnet-5",
            "openrouter:openai/gpt-5.5",
        ])
        #expect(models.map(\.displayName) == ["Claude Sonnet 5", "GPT-5.5"])
    }

    @Test("models() uses the Nous loader when model.provider is nous")
    func modelsFromNousProvider() async throws {
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") },
            configuredProviderResolver: { "nous" },
            catalogModelsLoader: { _ in
                Issue.record("Catalog loader must not run for nous")
                return []
            },
            nousModelsLoader: {
                [
                    AgentModel(id: "nous:anthropic/claude-sonnet-5", displayName: "anthropic/claude-sonnet-5"),
                ]
            }
        )

        let models = try await backend.models()
        #expect(models == [
            AgentModel(id: "nous:anthropic/claude-sonnet-5", displayName: "anthropic/claude-sonnet-5"),
        ])
    }

    @Test("models() stays empty when provider is missing or unknown")
    func modelsEmptyWithoutConfiguredProvider() async throws {
        for provider in [nil as String?, "", "  ", "unknown", "Unknown"] {
            let backend = HermesBackend(
                context: .local,
                installationProbe: { .available(version: "test") },
                configuredProviderResolver: { provider },
                catalogModelsLoader: { _ in
                    Issue.record("Catalog loader must not run without a real provider")
                    return []
                },
                nousModelsLoader: {
                    Issue.record("Nous loader must not run without a real provider")
                    return []
                }
            )
            #expect(try await backend.models().isEmpty)
        }
    }

    @Test("setSessionModel routes through the applier with provider and model split")
    func setSessionModelUsesApplier() async throws {
        final class Box: @unchecked Sendable {
            var calls: [(String, String, String?)] = []
        }
        let box = Box()
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") },
            sessionModelApplier: { sessionID, modelID, providerID in
                box.calls.append((sessionID, modelID, providerID))
            }
        )
        let session = AgentSession(id: "sess-1", backendID: .hermes)
        let parts = AgentModelPickerID.split("openrouter:anthropic/claude-sonnet-5")
        try await backend.setSessionModel(
            session: session,
            modelID: parts.modelID,
            providerID: parts.providerID
        )
        #expect(box.calls.count == 1)
        #expect(box.calls[0].0 == "sess-1")
        #expect(box.calls[0].1 == "anthropic/claude-sonnet-5")
        #expect(box.calls[0].2 == "openrouter")
    }

    @Test("setSessionModel without applier or active client fails")
    func setSessionModelRequiresActiveSession() async {
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") }
        )
        let session = AgentSession(id: "missing", backendID: .hermes)
        do {
            try await backend.setSessionModel(session: session, modelID: "m", providerID: "p")
            Issue.record("Expected session-not-active")
        } catch let error as AgentError {
            #expect(error.code == "hermes.session-not-active")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("setSessionModel applier errors propagate (busy)")
    func setSessionModelPropagatesBusy() async {
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") },
            sessionModelApplier: { _, _, _ in
                throw AgentError(
                    code: "hermes.set-model-busy",
                    message: "Session is busy",
                    isRecoverable: true
                )
            }
        )
        let session = AgentSession(id: "sess-busy", backendID: .hermes)
        do {
            try await backend.setSessionModel(session: session, modelID: "m", providerID: "openrouter")
            Issue.record("Expected busy error")
        } catch let error as AgentError {
            #expect(error.code == "hermes.set-model-busy")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("setSessionMode routes through the applier")
    func setSessionModeUsesApplier() async throws {
        final class Box: @unchecked Sendable {
            var calls: [(String, String)] = []
        }
        let box = Box()
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") },
            sessionModeApplier: { sessionID, modeID in
                box.calls.append((sessionID, modeID))
            }
        )
        let session = AgentSession(id: "sess-mode", backendID: .hermes)
        try await backend.setSessionMode(
            session: session,
            modeID: ACPApprovalMode.acceptEdits.rawValue
        )
        #expect(box.calls.count == 1)
        #expect(box.calls[0].0 == "sess-mode")
        #expect(box.calls[0].1 == "accept_edits")
    }

    @Test("setSessionMode without applier or active client fails")
    func setSessionModeRequiresActiveSession() async {
        let backend = HermesBackend(
            context: .local,
            installationProbe: { .available(version: "test") }
        )
        let session = AgentSession(id: "missing-mode", backendID: .hermes)
        do {
            try await backend.setSessionMode(session: session, modeID: "default")
            Issue.record("Expected session-not-active")
        } catch let error as AgentError {
            #expect(error.code == "hermes.session-not-active")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
