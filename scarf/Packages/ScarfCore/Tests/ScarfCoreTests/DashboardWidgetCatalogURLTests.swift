import Testing
@testable import ScarfCore

@Suite("Dashboard widget URL scheme")
struct DashboardWidgetCatalogURLTests {
    private func dashboard(url: String) -> ProjectDashboard {
        ProjectDashboard(
            version: 1,
            title: "D",
            description: nil,
            updatedAt: nil,
            theme: nil,
            sections: [
                DashboardSection(
                    title: "S",
                    columns: nil,
                    widgets: [DashboardWidget(type: "webview", title: "W", url: url)]
                )
            ]
        )
    }

    @Test func httpsURLIsAccepted() {
        #expect(DashboardWidgetCatalog.validate(dashboard(url: "https://example.com")).isEmpty)
    }

    @Test(arguments: ["http://localhost:8000", "file:///etc/passwd", "scarf-miniapp://app/index.html"])
    func nonHttpsURLIsRefused(url: String) {
        let problems = DashboardWidgetCatalog.validate(dashboard(url: url))
        #expect(problems.count == 1)
        #expect(problems[0].contains("https://"))
    }
}
