import Testing
@testable import ScarfCore

@Suite("Project watch sidecars")
struct ProjectWatchSetTests {
    @Test("a nil sidecar list keeps the files the dashboard installed")
    func nilSidecarsAreKept() {
        var set = ProjectWatchSet()
        set.update(
            dashboardPaths: ["/p/.scarf/dashboard.json"],
            scarfDirs: ["/p/.scarf"],
            sidecarPaths: ["/p/reports/uptime.log"]
        )
        set.update(
            dashboardPaths: ["/p/.scarf/dashboard.json"],
            scarfDirs: ["/p/.scarf"]
        )
        #expect(set.sidecarPaths == ["/p/reports/uptime.log"])
        #expect(set.union.contains("/p/reports/uptime.log"))
    }

    @Test("archiving a project drops its sidecar files")
    func archivedProjectDropsSidecars() {
        var set = ProjectWatchSet()
        set.update(
            dashboardPaths: ["/keep/.scarf/dashboard.json", "/gone/.scarf/dashboard.json"],
            scarfDirs: ["/keep/.scarf", "/gone/.scarf"],
            sidecarPaths: ["/keep/reports/a.log", "/gone/reports/b.log"]
        )
        set.update(
            dashboardPaths: ["/keep/.scarf/dashboard.json"],
            scarfDirs: ["/keep/.scarf"]
        )
        #expect(set.sidecarPaths == ["/keep/reports/a.log"])
    }

    @Test("the sidecar list is capped and de-duplicated")
    func capAndDedupe() {
        let paths = (0..<40).map { "/p/reports/\($0).log" } + ["/p/reports/0.log"]
        let capped = ProjectWatchSet.capped(paths)
        #expect(capped.count == ProjectWatchSet.sidecarCap)
        #expect(capped.first == "/p/reports/0.log")
        #expect(Set(capped).count == ProjectWatchSet.sidecarCap)
    }

    @Test("a sibling directory is not treated as inside the project")
    func prefixDoesNotEscape() {
        #expect(ProjectWatchSet.isUnderProject(
            "/proj/reports/uptime.log", scarfDirs: ["/proj/.scarf"]
        ))
        #expect(!ProjectWatchSet.isUnderProject(
            "/proj-other/reports/uptime.log", scarfDirs: ["/proj/.scarf"]
        ))
    }
}
