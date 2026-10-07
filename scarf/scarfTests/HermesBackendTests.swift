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
}
