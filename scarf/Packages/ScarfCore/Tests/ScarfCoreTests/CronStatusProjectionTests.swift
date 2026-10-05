import Testing
@testable import ScarfCore

@Suite("query:cron.status projection")
struct CronStatusProjectionTests {
    private let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test("encoded status omits prompt, script, extra, and error text")
    func encodedJSONOmitsRunText() throws {
        let secretPrompt = "PROMPT-DO-NOT-LEAK"
        let secretError = "ERROR-BODY-DO-NOT-LEAK"
        let secretScript = "SCRIPT-DO-NOT-LEAK"
        let job = HermesCronJob(
            id: "nightly",
            name: "[proj:\(projectID.uuidString)] Nightly",
            prompt: secretPrompt,
            schedule: CronSchedule(kind: "cron", display: "Daily at 9", expression: "0 9 * * *"),
            enabled: true,
            state: "scheduled",
            lastError: secretError,
            preRunScript: secretScript,
            extra: ["output_tail": .string("TAIL-DO-NOT-LEAK")]
        )
        let other = HermesCronJob(
            id: "foreign",
            name: "Someone else's job",
            prompt: "other-prompt",
            schedule: CronSchedule(kind: "cron", expression: "0 0 * * *"),
            enabled: true,
            state: "scheduled"
        )
        let json = CronStatusProjection.json(from: [job, other], projectID: projectID, templateId: nil)
        let rows = try JSONDecoder().decode([CronStatusProjection.Job].self, from: Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].id == "nightly")
        #expect(rows[0].schedule == "Daily at 9")
        #expect(rows[0].enabled == true)
        #expect(rows[0].state == "scheduled")
        #expect(!json.contains(secretPrompt))
        #expect(!json.contains(secretError))
        #expect(!json.contains(secretScript))
        #expect(!json.contains("TAIL-DO-NOT-LEAK"))
        #expect(!json.contains("other-prompt"))
        #expect(!json.contains("foreign"))
    }

    @Test("schedule falls back from display to expression, minutes, and kind")
    func scheduleFallback() {
        #expect(CronStatusProjection.scheduleText(
            CronSchedule(kind: "cron", expression: "*/15 * * * *")
        ) == "*/15 * * * *")
        #expect(CronStatusProjection.scheduleText(
            CronSchedule(kind: "interval", minutes: 15)
        ) == "every 15m")
        #expect(CronStatusProjection.scheduleText(
            CronSchedule(kind: "once", runAt: "2026-10-05T09:00:00Z")
        ) == "2026-10-05T09:00:00Z")
        #expect(CronStatusProjection.scheduleText(CronSchedule(kind: "cron")) == "cron")
    }
}
