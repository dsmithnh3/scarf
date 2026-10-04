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
}
