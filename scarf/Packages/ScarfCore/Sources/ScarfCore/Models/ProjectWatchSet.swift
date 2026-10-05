import Foundation

/// The project paths `HermesFileWatcher` observes: each project's
/// `dashboard.json`, its `.scarf/` directory, and the resolved files a
/// visible dashboard's `log_tail`, `markdown_file`, and local `image`
/// widgets read.
///
/// A directory watch does not fire on an in-place append, and a log
/// outside `.scarf/` (the schema's `reports/uptime.log`) is not inside
/// that directory at all. Those files are the sidecar list. Callers that
/// reload the registry pass `sidecarPaths: nil` so they do not drop a list
/// the open dashboard already installed. A shrinking project set (an
/// archived row leaves `scarfDirs`) drops sidecars that no longer sit
/// under a watched project.
public struct ProjectWatchSet: Equatable, Sendable {
    /// Enough for one dense dashboard. The open cockpit installs one
    /// project's files; this cap is that project's budget.
    public static let sidecarCap = 32

    public var dashboardPaths: [String]
    public var scarfDirs: [String]
    public var sidecarPaths: [String]

    public init(
        dashboardPaths: [String] = [],
        scarfDirs: [String] = [],
        sidecarPaths: [String] = []
    ) {
        self.dashboardPaths = dashboardPaths
        self.scarfDirs = scarfDirs
        self.sidecarPaths = sidecarPaths
    }

    /// Replace the dashboard and `.scarf/` halves. `sidecarPaths == nil`
    /// keeps the previous sidecar list, minus anything that escaped the
    /// projects still being watched. A non-nil list replaces it.
    public mutating func update(
        dashboardPaths: [String],
        scarfDirs: [String],
        sidecarPaths: [String]? = nil
    ) {
        self.dashboardPaths = dashboardPaths
        self.scarfDirs = scarfDirs
        if let sidecarPaths {
            self.sidecarPaths = Self.capped(sidecarPaths)
        } else {
            self.sidecarPaths = sidecarPathsContained(in: scarfDirs)
        }
    }

    /// Replace only the sidecar half. The open dashboard knows these
    /// paths and must not rewrite the project set a registry reload owns.
    public mutating func replaceSidecars(_ sidecarPaths: [String]) {
        self.sidecarPaths = Self.capped(sidecarPaths)
    }

    /// De-duplicated, original order, at most `sidecarCap` entries.
    public static func capped(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(min(paths.count, sidecarCap))
        for path in paths {
            guard seen.insert(path).inserted else { continue }
            out.append(path)
            if out.count == sidecarCap { break }
        }
        return out
    }

    /// Stable unique union the watcher actually arms.
    public var union: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in dashboardPaths + scarfDirs + sidecarPaths {
            if seen.insert(path).inserted { out.append(path) }
        }
        return out
    }

    private func sidecarPathsContained(in scarfDirs: [String]) -> [String] {
        sidecarPaths.filter { Self.isUnderProject($0, scarfDirs: scarfDirs) }
    }

    /// `scarfDirs` entries are `<project>/.scarf`. A sidecar is kept when
    /// it lives in that project, including files outside `.scarf/` itself.
    public static func isUnderProject(_ path: String, scarfDirs: [String]) -> Bool {
        for dir in scarfDirs {
            let root = dir.hasSuffix("/.scarf")
                ? String(dir.dropLast("/.scarf".count))
                : dir
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }
}
