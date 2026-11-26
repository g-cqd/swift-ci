public import Foundation

/// The repository's `.github/dependabot.yml`, written from what it holds (`swift-ci dependabot --write`) and checked by the
/// quality check: every package manifest and every workflow is in it, so one added later is not forgotten. The file sits at
/// the repository's top level; several packages of one repository each check the same file, so they keep this key alike.
public struct Dependabot: Codable, Sendable, Equatable {
    /// Whether swift-ci writes and checks the file; false leaves a hand-written one alone.
    public var enabled = true
    /// Package manifests left out, as globs on the manifest's path: fixtures and other inputs of tests.
    public var exclude: [String] = ["**/Fixtures/**", ".build/**"]
    /// The weekday of the weekly updates.
    public var day = "monday"

    public init() {}

    /// Where the file is, relative to the repository's top level.
    public static let path = ".github/dependabot.yml"
    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// The directories of the package manifests in `files`, `/` for the top level, sorted with it first.
    public func swiftDirectories(files: [String]) -> [String] {
        let excluded = exclude.map(Glob.init)
        let manifests = files.filter { file in
            (file == "Package.swift" || file.hasSuffix("/Package.swift")) && !excluded.contains { $0.matches(file) }
        }
        return Self.sorted(manifests.map(Self.directory(of:)))
    }

    /// `/` when there are workflows or a top-level action, and the directory of every other `action.yml`.
    public static func actionDirectories(files: [String]) -> [String] {
        let build = Glob(".build/**")
        var directories: Set<String> = []
        for file in files where !build.matches(file) {
            let name = file.split(separator: "/").last.map(String.init) ?? file
            if file.hasPrefix(".github/workflows/"), name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
                directories.insert("/")
            } else if name == "action.yml" || name == "action.yaml" {
                directories.insert(directory(of: file))
            }
        }
        return sorted(Array(directories))
    }

    /// The file for a repository holding `files` (paths relative to its top level), or nil when there is nothing to update.
    public func contents(files: [String]) -> String? {
        let swift = swiftDirectories(files: files)
        let actions = Self.actionDirectories(files: files)
        guard !swift.isEmpty || !actions.isEmpty else { return nil }
        var text = """
            # Dependabot, written by swift-ci (`swift-ci dependabot --write`) from the repository's manifests and workflows;
            # the quality check fails when it differs. Change the `dependabot` key of .ci/action.json, not this file.
            #
            # swift: the version requirements of each package manifest. Revision pins are not Dependabot's to move, and
            # its Swift updater may run an older toolchain than a manifest needs: that directory fails until it catches up.
            # github-actions: actions pinned by commit SHA, the version in a comment; Dependabot updates both.
            # One grouped pull request per ecosystem, weekly, so the CI runs stay few.
            version: 2
            updates:

            """
        if !swift.isEmpty {
            text += update(ecosystem: "swift", directories: swift, group: "swift-packages", prefix: "build", limit: 5)
        }
        if !actions.isEmpty {
            if !swift.isEmpty { text += "\n" }
            text += update(ecosystem: "github-actions", directories: actions, group: "github-actions", prefix: "ci")
        }
        return text
    }

    private func update(ecosystem: String, directories: [String], group: String, prefix: String, limit: Int? = nil)
        -> String
    {
        var lines = ["  - package-ecosystem: \"\(ecosystem)\"", "    directories:"]
        lines += directories.map { "      - \(Self.quoted($0))" }
        lines += ["    schedule:", "      interval: \"weekly\"", "      day: \"\(day)\""]
        if let limit { lines.append("    open-pull-requests-limit: \(limit)") }
        lines += ["    groups:", "      \(group):", "        patterns: [\"*\"]"]
        lines += ["    commit-message:", "      prefix: \"\(prefix)\""]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `/` and `/dir/sub` for `Package.swift` and `dir/sub/Package.swift`.
    static func directory(of file: String) -> String {
        guard let slash = file.lastIndex(of: "/") else { return "/" }
        return "/" + file[..<slash]
    }

    static func sorted(_ directories: [String]) -> [String] {
        Set(directories).sorted { ($0 == "/" ? 0 : 1, $0) < ($1 == "/" ? 0 : 1, $1) }
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    /// The repository's top level around `root`: git's, else `root`.
    public static func topLevel(of root: URL) -> URL {
        guard let line = try? Shell.output(["git", "rev-parse", "--show-toplevel"], directory: root, quiet: true),
            case let path = line.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return root }
        return URL(fileURLWithPath: path)
    }

    /// The files of the repository at `top`, relative to it: the tracked ones, else every file but build output.
    public static func files(top: URL) -> [String] {
        if let listed = try? Shell.output(["git", "ls-files", "-z"], directory: top, quiet: true) {
            return listed.split(separator: "\0").map(String.init)
        }
        let skipped: Set<String> = [".build", ".git", ".swiftpm", "DerivedData", "node_modules"]
        guard let walk = FileManager.default.enumerator(at: top, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        let base = top.standardizedFileURL.path
        var files: [String] = []
        for case let url as URL in walk {
            if skipped.contains(url.lastPathComponent) {
                walk.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
            files.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
        }
        return files.sorted()
    }

    /// Why the file at `top` is not the one swift-ci writes, or nil when it is (or there is nothing to update).
    public func drift(top: URL) -> String? {
        guard let expected = contents(files: Self.files(top: top)) else { return nil }
        let url = top.appendingPathComponent(Self.path)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else {
            return "\(Self.path) is missing: run `swift-ci dependabot --write`"
        }
        guard current != expected else { return nil }
        let wanted = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let found = current.split(separator: "\n", omittingEmptySubsequences: false)
        let line =
            zip(wanted, found).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(wanted.count, found.count)
        let expectedLine = line < wanted.count ? String(wanted[line]) : "(end of file)"
        return "\(Self.path) differs from what swift-ci writes at line \(line + 1) (expected: \(expectedLine)): "
            + "run `swift-ci dependabot --write`"
    }
}
