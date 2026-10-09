import Testing
@testable import ScarfCore

@Suite("AgentModelPickerID")
struct AgentModelPickerIDTests {
    @Test("split uses the first colon; encode round-trips catalog ids")
    func splitFirstColon() {
        let openrouter = AgentModelPickerID.split("openrouter:anthropic/claude-sonnet-5")
        #expect(openrouter.providerID == "openrouter")
        #expect(openrouter.modelID == "anthropic/claude-sonnet-5")
        #expect(
            ACPClient.encodeModelChoice(
                modelID: openrouter.modelID,
                providerID: openrouter.providerID
            ) == "openrouter:anthropic/claude-sonnet-5"
        )

        let nous = AgentModelPickerID.split("nous:anthropic/claude-sonnet-5")
        #expect(nous.providerID == "nous")
        #expect(nous.modelID == "anthropic/claude-sonnet-5")

        let multi = AgentModelPickerID.split("provider:model:with:colons")
        #expect(multi.providerID == "provider")
        #expect(multi.modelID == "model:with:colons")

        let bare = AgentModelPickerID.split("claude-sonnet-5")
        #expect(bare.providerID == nil)
        #expect(bare.modelID == "claude-sonnet-5")
    }
}
