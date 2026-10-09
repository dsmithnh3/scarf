import Foundation
import Testing
@testable import ScarfCore

@Suite("Session attribution recent IDs")
struct SessionAttributionRecentIDsTests {
    @Test("recentSessionIDs orders by touched descending for one project")
    func ordersByTouched() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-attr-recent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("scarf", isDirectory: true),
            withIntermediateDirectories: true
        )

        let context = ServerContext.local(home: home)
        let project = "/tmp/project-a"
        // Write distinct touched stamps so ordering does not depend on clock resolution.
        let map = SessionProjectMap(
            mappings: [
                "older": project,
                "newer": project,
                "other": "/tmp/other",
            ],
            updatedAt: "2026-01-03T00:00:00Z",
            touched: [
                "older": "2026-01-01T00:00:00Z",
                "newer": "2026-01-02T00:00:00Z",
                "other": "2026-01-03T00:00:00Z",
            ]
        )
        let data = try JSONEncoder().encode(map)
        try data.write(to: URL(fileURLWithPath: context.paths.sessionProjectMap))

        let ordered = SessionAttributionService(context: context)
            .recentSessionIDs(forProject: project)
        #expect(ordered == ["newer", "older"])
    }
}
