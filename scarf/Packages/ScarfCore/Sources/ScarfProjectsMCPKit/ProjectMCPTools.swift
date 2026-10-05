import Foundation
import ScarfCore

/// The `scarf-projects` tool surface: structured project CRUD for a
/// LOCAL Hermes agent, wrapping the exact services Scarf's own UI uses.
///
/// **No parallel write paths.** Every mutation goes through
/// `ProjectStore` / `ProjectDashboardService` / `ProjectSlashCommandService`
/// / `ProjectDoctorService`, which is the whole point: the skill's
/// "read `projects.json`, append your entry, write it back" step is what
/// produced the 2026-09-02 corruption, and a tool that hand-wrote JSON
/// would just be that same step with a schema stapled to the front.
///
/// **Every REGISTRY write honours the Phase-2 refusal.** A registry whose
/// decode dropped rows, or that was quarantined, is not writable:
/// rewriting it makes the loss permanent. `project_register` refuses, and
/// `project_validate`'s repairs are blocked by the doctor's own rule.
/// `project_update_dashboard` and `project_add_slash_command` write
/// PROJECT-LOCAL files and are not blocked by a damaged registry — but
/// they resolve their target through it, so every failure to resolve says
/// whether the registry was readable rather than claiming the project
/// doesn't exist.
///
/// All I/O is synchronous transport I/O on the process's own thread. That
/// is correct here and only here — this is a short-lived CLI with no main
/// actor to block (charter C10 is about the app).
public struct ProjectMCPTools: Sendable {

    /// One tool's outcome. `isError` maps to MCP's `tools/call` result
    /// flag: the call SUCCEEDED at protocol level and the model is meant
    /// to read the failure and react, which is exactly the affordance a
    /// hand-written file append never had.
    public struct Outcome: Sendable, Equatable {
        public let text: String
        public let isError: Bool

        public static func ok(_ text: String) -> Outcome { Outcome(text: text, isError: false) }
        public static func failure(_ text: String) -> Outcome { Outcome(text: text, isError: true) }
    }

    public let context: ServerContext
    /// Made once, like every other service here does — `project_list`
    /// touches the transport twice per project row.
    private let transport: any ServerTransport

    private let dashboards: ProjectDashboardService
    private let store: ProjectStore
    private let slashCommands: ProjectSlashCommandService
    private let doctor: ProjectDoctorService

    public init(context: ServerContext) {
        self.context = context
        self.transport = context.makeTransport()
        self.dashboards = ProjectDashboardService(context: context)
        self.store = ProjectStore(context: context)
        self.slashCommands = ProjectSlashCommandService(context: context)
        self.doctor = ProjectDoctorService(context: context)
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: JSONValue]) -> Outcome {
        do {
            switch name {
            case "project_list": return try list(arguments)
            case "project_get": return try get(arguments)
            case "project_register": return try register(arguments)
            case "project_update_dashboard": return try updateDashboard(arguments)
            case "project_add_slash_command": return try addSlashCommand(arguments)
            case "project_validate": return try validate(arguments)
            case "project_set_config": return try setConfig(arguments)
            default:
                return .failure(
                    "Unknown tool \"\(name)\". Available: "
                        + ProjectMCPToolCatalog.tools.map(\.name).joined(separator: ", ") + "."
                )
            }
        } catch let error as ArgumentError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - project_list

    private func list(_ arguments: [String: JSONValue]) throws -> Outcome {
        let includeArchived = try optionalBool(arguments, "includeArchived") ?? true
        let loaded = dashboards.loadRegistryDetailed()

        let rows = loaded.registry.projects
            .filter { includeArchived || !$0.archived }
            .map { entry -> JSONValue in
                var fields: [String: JSONValue] = [
                    "name": .string(entry.name),
                    "path": .string(entry.path),
                    "archived": .bool(entry.archived),
                    "hasRecord": .bool(
                        transport.fileExists(ProjectStore.recordPath(forProjectPath: entry.path))
                    ),
                    "hasDashboard": .bool(dashboards.dashboardExists(for: entry)),
                ]
                if let folder = entry.folder { fields["folder"] = .string(folder) }
                if let uuid = entry.uuid { fields["uuid"] = .string(uuid.uuidString) }
                return .object(fields)
            }

        return .ok(try render([
            "projects": .array(rows),
            "count": .int(rows.count),
            "registry": registryHealth(loaded),
        ]))
    }

    // MARK: - project_get

    private func get(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try requiredString(arguments, "project")
        let loaded = dashboards.loadRegistryDetailed()
        guard let entry = resolve(selector, in: loaded.registry.projects) else {
            return .failure(notFoundMessage(selector, in: loaded))
        }

        var fields: [String: JSONValue] = [
            "name": .string(entry.name),
            "path": .string(entry.path),
            "archived": .bool(entry.archived),
            "registry": registryHealth(loaded),
        ]
        if let folder = entry.folder { fields["folder"] = .string(folder) }
        if let uuid = entry.uuid { fields["uuid"] = .string(uuid.uuidString) }

        let recordPath = ProjectStore.recordPath(forProjectPath: entry.path)
        if transport.fileExists(recordPath) {
            if let record = store.load(projectPath: entry.path) {
                fields["record"] = .object([
                    "id": .string(record.id.uuidString),
                    "name": .string(record.name),
                    "rootPath": .string(record.rootPath),
                    "path": .string(recordPath),
                ])
            } else {
                fields["record"] = .object([
                    "path": .string(recordPath),
                    "error": .string(
                        "project.json exists but could not be parsed. It is left untouched — "
                            + "fix the file by hand, or run project_validate for a full report."
                    ),
                ])
            }
        }

        fields["dashboard"] = .object([
            "path": .string(entry.dashboardPath),
            "exists": .bool(dashboards.dashboardExists(for: entry)),
            "valid": .bool(dashboards.loadDashboard(for: entry) != nil),
        ])
        fields["slashCommands"] = .array(
            slashCommands.loadCommands(at: entry.path).map { .string($0.name) }
        )

        if let tenant = KanbanTenantReader(context: context).tenant(forProjectPath: entry.path) {
            fields["kanbanTenant"] = .string(tenant)
        }
        if let uuid = entry.uuid {
            fields["cronNamePrefix"] = .string(ProjectCronAttribution.projectTag(uuid) + " ")
        }

        return .ok(try render(fields))
    }

    // MARK: - project_register

    private func register(_ arguments: [String: JSONValue]) throws -> Outcome {
        let name = try requiredString(arguments, "name")
        let rawPath = try requiredString(arguments, "path")

        if name.contains("/") || name.contains("\n") {
            return .failure("name must be a display name, not a path (got \"\(name)\").")
        }
        guard rawPath.hasPrefix("/") else {
            return .failure(
                "path must be absolute (got \"\(rawPath)\"). A `~` is not expanded — pass the "
                    + "resolved home directory instead."
            )
        }
        let path = ProjectIdentity.normalizedPath(rawPath)
        if let refusal = ProjectRootPolicy.refusal(for: path, context: context) {
            return .failure(refusal.message)
        }
        guard transport.fileExists(path) else {
            return .failure(
                "No directory at \(path). Create the project folder first — registering a "
                    + "project never creates its directory."
            )
        }

        let loaded = dashboards.loadRegistryDetailed()
        if let refusal = lossyRefusal(loaded, verb: "register “\(name)”") {
            return .failure(refusal)
        }

        if let clash = loaded.registry.projects.first(where: { $0.name == name }) {
            return .failure(
                "A project named “\(name)” is already registered at \(clash.path). "
                    + "The registry keys the sidebar on the display name, so names must be unique."
            )
        }
        if let existing = loaded.registry.projects.first(where: {
            ProjectIdentity.normalizedPath($0.path) == path
                || (!context.isRemote && ProjectIdentity.mayBeSameLocalItem($0.path, path))
        }) {
            return .failure(
                "\(path) is already registered as “\(existing.name)”. Use project_get to inspect "
                    + "it, or rename it in Scarf — re-registering the same path under a second "
                    + "name would give one folder two identities."
            )
        }

        let project = store.derive(from: ProjectEntry(name: name, path: path))

        do {
            try store.save(project)
        } catch {
            let recordPath = ProjectStore.recordPath(forProjectPath: path)
            let partial = transport.fileExists(recordPath)
                ? " The record at \(recordPath) WAS written; only the registry row is missing — "
                    + "run project_validate, which offers to re-index it."
                : ""
            return .failure(
                "Could not register “\(name)”: \(error.localizedDescription)" + partial
            )
        }

        return .ok(try render([
            "registered": .bool(true),
            "name": .string(name),
            "path": .string(path),
            "uuid": .string(project.id.uuidString),
            "recordPath": .string(ProjectStore.recordPath(forProjectPath: path)),
            "registryPath": .string(context.paths.projectsRegistry),
        ]))
    }

    // MARK: - project_update_dashboard

    private func updateDashboard(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try requiredString(arguments, "project")
        let loaded = dashboards.loadRegistryDetailed()
        guard let entry = resolve(selector, in: loaded.registry.projects) else {
            return .failure(notFoundMessage(selector, in: loaded))
        }

        guard let raw = arguments["dashboard"] else {
            throw ArgumentError(message: "Missing required argument \"dashboard\".")
        }
        let bytes: Data
        switch raw {
        case .string(let text):
            bytes = Data(text.utf8)
        case .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bytes = try encoder.encode(raw)
        default:
            throw ArgumentError(
                message: "\"dashboard\" must be a JSON object (or a string containing one)."
            )
        }

        do {
            try dashboards.saveDashboard(rawJSON: bytes, for: entry)
        } catch let error as ProjectDashboardWriteError {
            return .failure(
                (error.errorDescription ?? "Dashboard rejected.")
                    + " Nothing was written; the existing dashboard.json is untouched."
            )
        } catch {
            return .failure("Could not write dashboard.json: \(error.localizedDescription)")
        }

        return .ok(try render([
            "written": .bool(true),
            "project": .string(entry.name),
            "path": .string(entry.dashboardPath),
        ]))
    }

    // MARK: - project_add_slash_command

    private func addSlashCommand(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try requiredString(arguments, "project")
        let loaded = dashboards.loadRegistryDetailed()
        guard let entry = resolve(selector, in: loaded.registry.projects) else {
            return .failure(notFoundMessage(selector, in: loaded))
        }

        let name = try requiredString(arguments, "name")
        let description = try requiredString(arguments, "description")
        let body = try requiredString(arguments, "body")
        let overwrite = try optionalBool(arguments, "overwrite") ?? false

        if let reason = ProjectSlashCommand.validateName(name) {
            return .failure("\"name\" is not a usable command name: \(reason)")
        }
        let dir = ProjectSlashCommandService.slashCommandsDir(for: entry.path)
        let commandPath = dir + "/" + name + ".md"
        if !overwrite, transport.fileExists(commandPath) {
            return .failure(
                "/\(name) already exists at \(commandPath). Pass overwrite: true to replace it."
            )
        }

        let command = ProjectSlashCommand(
            name: name,
            description: description,
            argumentHint: try optionalString(arguments, "argumentHint"),
            model: try optionalString(arguments, "model"),
            tags: try optionalStringArray(arguments, "tags"),
            body: body,
            sourcePath: commandPath
        )
        do {
            try slashCommands.save(command, at: entry.path)
        } catch {
            return .failure("Could not write /\(name): \(error.localizedDescription)")
        }

        return .ok(try render([
            "written": .bool(true),
            "command": .string("/" + name),
            "project": .string(entry.name),
            "path": .string(commandPath),
        ]))
    }

    // MARK: - project_set_config

    static let configMaxBytes = 1 * 1024 * 1024

    private func setConfig(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try requiredString(arguments, "project")
        let loaded = dashboards.loadRegistryDetailed()
        guard let entry = resolve(selector, in: loaded.registry.projects) else {
            return .failure(notFoundMessage(selector, in: loaded))
        }

        let key = try requiredString(arguments, "key")
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return .failure(
                "\"key\" (\"\(key)\") must contain only letters, digits, '-', '_' or '.'."
            )
        }
        guard let rawValue = arguments["value"] else {
            throw ArgumentError(message: "Missing required argument \"value\".")
        }
        let requestedSecret = try optionalBool(arguments, "secret") ?? false

        if case .string(let s) = rawValue, s.hasPrefix("keychain://") {
            return .failure(
                "\"value\" may not be a keychain:// reference — refs are minted internally by "
                    + "this tool when secret: true. Pass the plaintext secret instead."
            )
        }

        let manifestPath = entry.path + "/.scarf/manifest.json"
        var templateID: String?
        var schemaFieldIsSecret: Bool?
        var schemaKnowsField = false
        if transport.fileExists(manifestPath) {
            if let data = try? transport.readFile(manifestPath),
               let manifest = try? JSONDecoder().decode(JSONValue.self, from: data),
               case .object(let root) = manifest {
                if case .string(let id) = root["id"] { templateID = id }
                if case .object(let config) = root["config"],
                   case .array(let fields) = config["schema"] {
                    for field in fields {
                        guard case .object(let f) = field,
                              case .string(let fieldKey) = f["key"] else { continue }
                        if fieldKey == key {
                            schemaKnowsField = true
                            if case .string(let type) = f["type"] {
                                schemaFieldIsSecret = (type == "secret")
                            }
                        }
                    }
                }
            }
        }
        if schemaKnowsField, let declaredSecret = schemaFieldIsSecret,
           declaredSecret != requestedSecret {
            return .failure(
                declaredSecret
                    ? "\"\(key)\" is declared `secret` in this project's template. "
                        + "Pass secret: true."
                    : "\"\(key)\" is not a secret field in this project's template. "
                        + "Pass secret: false (or omit it)."
            )
        }

        let configPath = entry.path + "/.scarf/config.json"
        let guarded = GuardedJSONStore(transport: transport, label: "config.json")
        let (inspection, existingRoot) = guarded.inspectDecoding(
            JSONValue.self, at: configPath, maxBytes: Self.configMaxBytes
        )
        if case .unreadable = inspection.state {
            return .failure(
                "\(configPath) exists but couldn't be read. Refusing to rewrite it — that would "
                    + "orphan every other value in it, including any Keychain references. Fix the "
                    + "file (or its permissions) and retry."
            )
        }
        var root: [String: JSONValue] = [:]
        if let existingRoot, case .object(let object) = existingRoot { root = object }
        var values: [String: JSONValue] = [:]
        var existingTemplateID = templateID ?? "unknown"
        if case .object(let existingValues) = root["values"] { values = existingValues }
        if case .string(let id) = root["templateId"] { existingTemplateID = id }

        let responseFields: [String: JSONValue]
        if requestedSecret {
            guard case .string(let secretText) = rawValue, !secretText.isEmpty else {
                return .failure("A secret \"value\" must be a non-empty string.")
            }
            guard let slugSource = templateID else {
                return .failure(
                    "This project has no cached template manifest (\(manifestPath)), so there is "
                        + "no template slug to namespace the Keychain item under. Secret fields "
                        + "require a template-installed project; set non-secret values instead, "
                        + "or use Scarf's Configuration UI."
                )
            }
            let slug = TemplateSlug.derive(fromID: slugSource)
            let ref = TemplateKeychainRef.make(
                templateSlug: slug,
                fieldKey: key,
                projectPath: entry.path
            )
            do {
                try ProjectConfigKeychain().set(ref: ref, secret: Data(secretText.utf8))
            } catch {
                return .failure("Could not write \"\(key)\" to the Keychain: \(error.localizedDescription)")
            }
            values[key] = .string(ref.uri)
            responseFields = [
                "written": .bool(true),
                "project": .string(entry.name),
                "key": .string(key),
                "secret": .bool(true),
                "keychainService": .string(ref.service),
                "path": .string(configPath),
            ]
        } else {
            switch rawValue {
            case .string, .int, .double, .bool: break
            case .array(let items):
                guard items.allSatisfy({ if case .string = $0 { return true } else { return false } }) else {
                    return .failure("\"value\" arrays must contain only strings.")
                }
            default:
                return .failure(
                    "\"value\" must be a string, number, boolean, or array of strings."
                )
            }
            values[key] = rawValue
            responseFields = [
                "written": .bool(true),
                "project": .string(entry.name),
                "key": .string(key),
                "secret": .bool(false),
                "path": .string(configPath),
            ]
        }

        root["schemaVersion"] = .int(2)
        root["templateId"] = .string(existingTemplateID)
        root["values"] = .object(values)
        root["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(JSONValue.object(root))
            try guarded.write(data, to: configPath, after: inspection)
        } catch {
            return .failure("Could not write \(configPath): \(error.localizedDescription)")
        }

        return .ok(try render(responseFields))
    }

    // MARK: - project_validate

    private func validate(_ arguments: [String: JSONValue]) throws -> Outcome {
        let selector = try optionalString(arguments, "project")
        let shouldRepair = try optionalBool(arguments, "repair") ?? false

        var entry: ProjectEntry?
        if let selector {
            let loaded = dashboards.loadRegistryDetailed()
            guard let found = resolve(selector, in: loaded.registry.projects) else {
                return .failure(notFoundMessage(selector, in: loaded))
            }
            entry = found
        }

        var report = doctor.diagnose()
        var repaired: [String] = []
        var repairFailures: [String: String] = [:]

        if shouldRepair {
            let scoped = entry.map { subject in
                ProjectDoctorReport(
                    findings: findings(of: report, concerning: subject),
                    repairBlock: report.repairBlock,
                    projectCount: report.projectCount,
                    generatedAt: report.generatedAt
                )
            } ?? report

            let attempted = scoped.safelyRepairable.map(\ProjectDoctorFinding.id)
            repairFailures = doctor.repairAllSafe(scoped)
            repaired = attempted.filter { repairFailures[$0] == nil }
            report = doctor.diagnose()
        }

        let scopedFindings = entry.map { findings(of: report, concerning: $0) } ?? report.findings

        var fields: [String: JSONValue] = [
            "summary": .string(report.summary),
            "projectCount": .int(report.projectCount),
            "healthy": .bool(scopedFindings.filter { $0.severity > .info }.isEmpty),
            "findings": .array(scopedFindings.map(encode)),
        ]
        if let entry { fields["project"] = .string(entry.name) }
        if let block = report.repairBlock {
            fields["repairsBlocked"] = .string(block.message)
        }
        if shouldRepair {
            fields["repaired"] = .array(repaired.map { .string($0) })
            if !repairFailures.isEmpty {
                fields["repairFailures"] = .object(
                    repairFailures.mapValues { JSONValue.string($0) }
                )
            }
        }
        return .ok(try render(fields))
    }

    private func findings(
        of report: ProjectDoctorReport,
        concerning subject: ProjectEntry
    ) -> [ProjectDoctorFinding] {
        report.findings.filter { finding in
            if finding.projectName == subject.name { return true }
            guard let path = finding.path else { return false }
            return path == subject.path || path.hasPrefix(subject.path + "/")
        }
    }

    private func encode(_ finding: ProjectDoctorFinding) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(finding.id),
            "kind": .string(finding.kind.rawValue),
            "severity": .string(String(describing: finding.severity)),
            "title": .string(finding.title),
            "detail": .string(finding.detail),
        ]
        if let name = finding.projectName { fields["project"] = .string(name) }
        if let path = finding.path { fields["path"] = .string(path) }
        if let repair = finding.repair {
            fields["repair"] = .object([
                "action": .string(repair.actionLabel),
                "safe": .bool(repair.isSafe),
                "destructive": .bool(repair.isDestructive),
            ])
        }
        return .object(fields)
    }

    // MARK: - Shared helpers

    private func resolve(_ selector: String, in rows: [ProjectEntry]) -> ProjectEntry? {
        if let byName = rows.first(where: { $0.name == selector }) { return byName }
        guard selector.hasPrefix("/") else { return nil }
        let normalized = ProjectIdentity.normalizedPath(selector)
        return rows.first { ProjectIdentity.normalizedPath($0.path) == normalized }
    }

    private func notFoundMessage(
        _ selector: String,
        in loaded: ProjectDashboardService.RegistryLoadResult
    ) -> String {
        let known = loaded.registry.projects.map(\.name).sorted()
        let head = "No project matches \"\(selector)\" (name or absolute path). "
        if loaded.salvaged {
            let damage = loaded.quarantinePath.map {
                "The registry at \(context.paths.projectsRegistry) could not be read at all and "
                    + "was set aside at \($0), so this list is empty for that reason — not "
                    + "because you have no projects."
            } ?? "\(loaded.salvage.droppedCount) row(s) in the registry could not be read, so "
                + "some projects are missing from this list."
            let visible = known.isEmpty ? "" : " Readable projects: " + known.joined(separator: ", ") + "."
            return head + damage + visible + " Run project_validate."
        }
        let list = known.isEmpty
            ? "No projects are registered yet — use project_register."
            : "Known projects: " + known.joined(separator: ", ") + "."
        return head + list
    }

    private func registryHealth(
        _ loaded: ProjectDashboardService.RegistryLoadResult
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "path": .string(context.paths.projectsRegistry),
            "healthy": .bool(!loaded.salvaged),
        ]
        if loaded.salvaged {
            fields["droppedRows"] = .int(loaded.salvage.droppedCount)
            if let quarantine = loaded.quarantinePath {
                fields["quarantinePath"] = .string(quarantine)
            }
            fields["warning"] = .string(
                "The projects registry did not decode cleanly. Writes are refused until it is "
                    + "repaired, so a rewrite can't make the loss permanent. Run project_validate."
            )
        }
        return .object(fields)
    }

    private func lossyRefusal(
        _ loaded: ProjectDashboardService.RegistryLoadResult,
        verb: String
    ) -> String? {
        guard let loss = loaded.loss else { return nil }
        return "Refusing to \(verb). \(loss.message) "
            + "Run project_validate for what is wrong with \(context.paths.projectsRegistry)."
    }

    private func render(_ fields: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(fields)), as: UTF8.self)
    }

    // MARK: - Argument coercion

    struct ArgumentError: Error { let message: String }

    private func requiredString(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key] else {
            throw ArgumentError(message: "Missing required argument \"\(key)\".")
        }
        guard case .string(let text) = value else {
            throw ArgumentError(message: "\"\(key)\" must be a string.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ArgumentError(message: "\"\(key)\" must not be empty.")
        }
        return trimmed
    }

    private func optionalString(_ arguments: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = arguments[key], value != .null else { return nil }
        guard case .string(let text) = value else {
            throw ArgumentError(message: "\"\(key)\" must be a string.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalBool(_ arguments: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = arguments[key], value != .null else { return nil }
        switch value {
        case .bool(let flag):
            return flag
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: break
            }
            throw ArgumentError(message: "\"\(key)\" must be true or false (got \"\(text)\").")
        default:
            throw ArgumentError(message: "\"\(key)\" must be true or false.")
        }
    }

    private func optionalStringArray(
        _ arguments: [String: JSONValue],
        _ key: String
    ) throws -> [String]? {
        guard let value = arguments[key], value != .null else { return nil }
        guard case .array(let items) = value else {
            throw ArgumentError(message: "\"\(key)\" must be an array of strings.")
        }
        var result: [String] = []
        for item in items {
            guard case .string(let text) = item else {
                throw ArgumentError(message: "\"\(key)\" must contain only strings.")
            }
            result.append(text)
        }
        return result.isEmpty ? nil : result
    }
}
