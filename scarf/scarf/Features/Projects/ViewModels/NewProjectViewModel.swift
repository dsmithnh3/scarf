import Foundation
import os
import Observation
import ScarfCore

struct NewProjectAgentOption: Identifiable, Equatable, Sendable {
    let id: AgentID
    let displayName: String
    let detail: String
}

/// State + commit logic for the "New Project from Scratch" wizard.
/// Drives `NewProjectSheet`. Hosts the form fields, derives a default
/// slug from the project name, validates inputs, probes available agent
/// runtimes, and runs the `ProjectScaffolder` on commit.
@Observable
@MainActor
final class NewProjectViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "NewProjectViewModel")
    private let context: ServerContext
    private let agentRuntime: AgentRuntime

    // MARK: - Form fields

    var projectName: String = "" {
        didSet {
            if !slugManuallyEdited {
                folderName = ProjectScaffolder.suggestedSlug(from: projectName)
            }
        }
    }

    var folderName: String = "" {
        didSet {
            if folderName != ProjectScaffolder.suggestedSlug(from: projectName) {
                slugManuallyEdited = true
            }
        }
    }

    var parentDirectory: String = ""
    var description: String = ""

    /// Hermes is the compatibility default. Claude is appended only after its
    /// executable probe succeeds in this window's local runtime context.
    var selectedAgentID: AgentID = .hermes
    private(set) var agentOptions: [NewProjectAgentOption] = [
        NewProjectAgentOption(
            id: .hermes,
            displayName: "Hermes",
            detail: "Scarf's existing full-featured agent runtime"
        )
    ]
    private(set) var isCheckingAgentBackends = false
    private(set) var agentAvailabilityNote: String?

    /// User-facing error from the most recent commit attempt.
    var errorMessage: String?

    // MARK: - Internal state

    private var slugManuallyEdited: Bool = false
    private(set) var isCommitting: Bool = false

    init(context: ServerContext) {
        self.context = context
        self.agentRuntime = AgentRuntime(context: context)
        self.parentDirectory = Self.defaultParentDirectory()
    }

    // MARK: - Agent availability

    func refreshAgentOptions() async {
        guard !isCheckingAgentBackends else { return }
        isCheckingAgentBackends = true
        defer { isCheckingAgentBackends = false }

        let snapshots = await agentRuntime.statusSnapshots()
        let presentation = ProjectAgentPreferencePresenter.make(
            preferredAgentID: selectedAgentID,
            probes: snapshots.map { snapshot in
                ProjectAgentBackendProbe(
                    id: snapshot.id,
                    displayName: snapshot.displayName,
                    executablePath: snapshot.executablePath,
                    status: snapshot.status
                )
            },
            isRemoteContext: context.isRemote
        )
        agentOptions = presentation.options.map {
            NewProjectAgentOption(
                id: $0.id,
                displayName: $0.displayName,
                detail: $0.detail
            )
        }
        selectedAgentID = presentation.selectedAgentID
        agentAvailabilityNote = presentation.availabilityNote
    }

    // MARK: - Validation

    var canCommit: Bool {
        guard !isCommitting else { return false }
        guard !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard ProjectScaffolder.isValidSlug(folderName) else { return false }
        guard !parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard agentOptions.contains(where: { $0.id == selectedAgentID }) else {
            return false
        }
        return true
    }

    var resolvedProjectPath: String {
        let parent = ProjectScaffolder.normalizeDirectoryPath(parentDirectory)
        return parent + "/" + folderName
    }

    // MARK: - Commit

    func commit() async -> ProjectEntry? {
        guard canCommit else {
            errorMessage = "Fill in the name, folder, parent directory, and choose an available agent."
            return nil
        }
        guard !isCommitting else { return nil }
        isCommitting = true
        errorMessage = nil

        let ctx = context
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = folderName
        let parent = parentDirectory
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredAgentID = selectedAgentID

        let result: Result<ProjectEntry, Error> = await Task.detached { [logger] in
            Self.scaffoldOffMain(
                context: ctx,
                name: name,
                slug: slug,
                parentDir: parent,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                preferredAgentID: preferredAgentID,
                logger: logger
            )
        }.value

        isCommitting = false
        switch result {
        case .success(let entry):
            logger.info("scaffolded \(entry.name, privacy: .public) at \(entry.path, privacy: .public)")
            return entry
        case .failure(let error):
            errorMessage = error.localizedDescription
            logger.warning("scaffold failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func scaffoldOffMain(
        context: ServerContext,
        name: String,
        slug: String,
        parentDir: String,
        description: String?,
        preferredAgentID: AgentID,
        logger: Logger
    ) -> Result<ProjectEntry, Error> {
        let scaffolder = ProjectScaffolder(context: context)
        do {
            let entry = try scaffolder.scaffold(
                name: name,
                slug: slug,
                parentDir: parentDir,
                description: description,
                preferredAgentID: preferredAgentID
            )

            // Hermes' new-project flow uses its bundled project-author skill.
            // Claude receives a backend-neutral kickoff instead, so don't do
            // Hermes-specific bootstrap work for a Claude-selected project.
            if preferredAgentID == .hermes {
                do {
                    try SkillBootstrapService(context: context).ensureBundledSkillsInstalled()
                } catch {
                    logger.warning(
                        "skill preflight failed for new-project wizard: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return .success(entry)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Initial chat prompt

    func buildInitialPrompt(for entry: ProjectEntry) -> String {
        if selectedAgentID == .hermes {
            return buildHermesInitialPrompt(for: entry)
        }
        return buildGenericAgentInitialPrompt(for: entry)
    }

    private func buildHermesInitialPrompt(for entry: ProjectEntry) -> String {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = """
        SKILL: scarf-template-author
        PROJECT_PATH: \(entry.path)
        PROJECT_NAME: \(entry.name)

        Run the `scarf-template-author` skill interview now. This is a freshly-scaffolded Scarf project with an empty dashboard; Scarf supplies its project context. Walk me through:

        1. Purpose + data source — what does this project do and where does its data come from?
        2. Dashboard widgets — pick from the supported widget vocabulary documented in the skill.
        3. Configuration schema — only if the project takes user-supplied inputs (URLs, API tokens, etc.).
        4. Scheduled jobs — only if data needs periodic refresh.
        5. Write everything to disk and confirm the project is ready.

        Start with question 1.
        """
        if !trimmedDescription.isEmpty {
            prompt += "\n\nFor question 1, the user already wrote: \"\(trimmedDescription)\". Confirm your understanding and move directly to question 2."
        }
        return prompt
    }

    private func buildGenericAgentInitialPrompt(for entry: ProjectEntry) -> String {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = """
        PROJECT_PATH: \(entry.path)
        PROJECT_NAME: \(entry.name)

        This is a freshly scaffolded Scarf project and you are its configured coding agent. Work inside PROJECT_PATH. First inspect the files Scarf created, especially `.scarf/project.json`, `.scarf/dashboard.json`, and `AGENTS.md` when present. Preserve Scarf-managed metadata and do not replace the project identity record.

        Help me turn this scaffold into the real project. Start by confirming the project's purpose and data source, then propose the smallest useful implementation and any Scarf dashboard/configuration changes that are justified by the files and conventions you can verify. Ask before inventing external services, credentials, or schemas you cannot infer safely.
        """
        if !trimmedDescription.isEmpty {
            prompt += "\n\nThe user described the project as: \"\(trimmedDescription)\". Use that as the starting context and ask only the next information you actually need."
        }
        return prompt
    }

    // MARK: - Defaults

    private static func defaultParentDirectory() -> String {
        let home = NSHomeDirectory()
        let projectsDir = home + "/Projects"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectsDir, isDirectory: &isDir),
           isDir.boolValue {
            return projectsDir
        }
        return home
    }
}
