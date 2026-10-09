import Foundation

/// The status fields a mini-app may see for cron jobs attributed to one
/// project. The prompt, script, `extra` bag, output tail, and error body
/// stay on `HermesCronJob` and are not encoded here.
public enum CronStatusProjection {
    public struct Job: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let schedule: String
        public let enabled: Bool
        public let state: String

        public init(id: String, name: String, schedule: String, enabled: Bool, state: String) {
            self.id = id
            self.name = name
            self.schedule = schedule
            self.enabled = enabled
            self.state = state
        }
    }

    /// Human schedule when Hermes stored one, otherwise the expression,
    /// the interval, the one-shot time, or the kind.
    public static func scheduleText(_ schedule: CronSchedule) -> String {
        if let display = schedule.display, !display.isEmpty { return display }
        if let expression = schedule.expression, !expression.isEmpty { return expression }
        if let minutes = schedule.minutes { return "every \(minutes)m" }
        if let runAt = schedule.runAt, !runAt.isEmpty { return runAt }
        return schedule.kind
    }

    /// Jobs whose name attributes them to `projectID` (and, when the
    /// project was installed from a template, that template).
    public static func jobs(
        from jobs: [HermesCronJob],
        projectID: UUID,
        templateId: String?
    ) -> [Job] {
        jobs.compactMap { job in
            guard ProjectCronAttribution.isAttributed(
                jobName: job.name, projectID: projectID, templateId: templateId
            ) else { return nil }
            return Job(
                id: job.id,
                name: job.name,
                schedule: scheduleText(job.schedule),
                enabled: job.enabled,
                state: job.effectiveState
            )
        }
    }

    public static func json(
        from jobs: [HermesCronJob],
        projectID: UUID,
        templateId: String?
    ) -> String {
        let rows = self.jobs(from: jobs, projectID: projectID, templateId: templateId)
        guard let data = try? JSONEncoder().encode(rows),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
