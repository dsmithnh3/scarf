import Foundation

public extension ProjectStore {
    /// Persist the backend selected for new agent sessions in a project.
    ///
    /// Projects with no explicit preference remain Hermes by compatibility
    /// default. Existing canonical records are mutated in place so unknown
    /// future metadata in `ScarfProject.extra` survives the write. A missing
    /// record is derived through the existing ProjectStore path before saving,
    /// preserving any registry UUID and other already-known project facets.
    nonisolated func setPreferredAgentID(
        _ agentID: AgentID,
        projectPath: String,
        name: String
    ) throws {
        var project: ScarfProject

        switch loadDetailed(projectPath: projectPath) {
        case .loaded(let existing):
            project = existing
        case .absent:
            project = loadOrDerive(projectPath: projectPath, name: name)
        case .unreadable(let path):
            throw ProjectStoreError.refusedUnreadableRecord(path: path)
        }

        project.preferredAgentID = agentID
        project.updatedAt = Date()
        try save(project)
    }
}
