import Foundation

extension Executor {
    /// The benchmarks at the commit before, in a worktree of the project's own name beside it, then here; the two
    /// baselines compared into the job's summary and checked against the tolerances the benchmarks declare.
    func compare(_ comparison: BenchmarkComparison) throws {
        let base = try revision(BenchmarkComparison.base(from: GitHubContext.current.base))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-ci-bench-\(UUID().uuidString)"
        )
        let tree = parent.appendingPathComponent(root.lastPathComponent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            _ = try? Shell.output(["git", "worktree", "remove", "--force", tree.path], directory: root, quiet: true)
            try? FileManager.default.removeItem(at: parent)
        }
        try Shell.run(["git", "worktree", "add", "--detach", "--quiet", tree.path, base], directory: root)
        // One toolchain for both: the commit before builds with the Swift this run selected (`swiftly use` rewrote the project's
        // `.swift-version`; the commit before still names the one it was written with, which the runner may not have).
        let version = root.appendingPathComponent(".swift-version")
        if FileManager.default.fileExists(atPath: version.path) {
            let copy = tree.appendingPathComponent(".swift-version")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: version, to: copy)
        }
        for path in comparison.shared
        where FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let link = tree.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(path))
        }
        print("swift-ci: benchmarks at \(base), the commit before")
        try Shell.run(comparison.recordArguments("base"), directory: tree)
        try adoptBaselines(of: comparison.package, from: tree)
        print("swift-ci: benchmarks here")
        try Shell.run(comparison.recordArguments("head"), directory: root)

        let report = try Shell.combinedOutput(
            comparison.comparisonArguments("compare", base: "base", head: "head", markdown: true),
            directory: root
        )
        print(report.output)
        if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] {
            Self.appendSummary("## Benchmarks against \(base.prefix(7))\n\n\(report.output)\n", to: summary)
        }
        let check = try Shell.combinedOutput(
            comparison.comparisonArguments("check", base: "base", head: "head"),
            directory: root
        )
        print(check.output)
        switch BenchmarkComparison.verdict(status: check.status, output: check.output) {
            case .equal: print("swift-ci: benchmarks within their tolerances")
            case .improved: print("swift-ci: benchmarks improved")
            case .regressed: throw SwiftCIError("benchmark: a regression past the benchmarks' tolerances (above)")
            case .failed(let reason): throw SwiftCIError("benchmark: \(reason)")
        }
    }

    /// Text added to the job's summary; a summary that cannot be written loses the table, never the verdict.
    static func appendSummary(_ text: String, to path: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// A commit, fetched when the clone is shallow; `HEAD^` resolved to its hash.
    func revision(_ name: String) throws -> String {
        if let found = try? Shell.output(
            ["git", "rev-parse", "--verify", "-q", name + "^{commit}"],
            directory: root,
            quiet: true
        ) {
            return found.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name == "HEAD^" {
            let head = try Shell.output(["git", "rev-parse", "HEAD"], directory: root, quiet: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Shell.run(["git", "fetch", "--no-tags", "--depth=2", "origin", head], directory: root)
        } else {
            try Shell.run(["git", "fetch", "--no-tags", "--depth=1", "origin", name], directory: root)
        }
        return try Shell.output(["git", "rev-parse", "--verify", name + "^{commit}"], directory: root, quiet: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `base` baseline of each benchmark target, from the other tree into this one (`.benchmarkBaselines/<target>/base`).
    private func adoptBaselines(of package: String, from tree: URL) throws {
        let manager = FileManager.default
        let from = tree.appendingPathComponent(package).appendingPathComponent(".benchmarkBaselines")
        let into = root.appendingPathComponent(package).appendingPathComponent(".benchmarkBaselines")
        let targets = try manager.contentsOfDirectory(atPath: from.path)
        guard !targets.isEmpty else { throw SwiftCIError("benchmark: the commit before stored no baseline") }
        for target in targets {
            let source = from.appendingPathComponent(target).appendingPathComponent("base")
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = into.appendingPathComponent(target).appendingPathComponent("base")
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: source, to: destination)
        }
    }
}
