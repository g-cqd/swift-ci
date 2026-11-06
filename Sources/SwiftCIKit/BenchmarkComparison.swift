import Foundation

/// An ordo-one benchmark package run on the commit before and on this one, on the same runner, and compared
/// (`"benchmark": {…}`): a regression past the tolerances the benchmarks declare in their code fails the command.
/// Nothing is stored between runs, so a new toolchain or runner never trips it. Only deterministic metrics are taken
/// (instructions and allocations by default), since time on a shared runner is noise.
///
/// The commit before is the push's previous head, the base of a pull request, or `HEAD^` for a scheduled or dispatched
/// run. It is checked out beside the project, in a directory of the project's own name (a package's identity is its
/// directory's name), with `shared` paths (fetched fixtures) linked in from the project.
public struct BenchmarkComparison: Codable, Sendable, Equatable {
    /// The benchmark package, relative to the root.
    public var package: String = "Benchmarks"
    /// Benchmarks to run (`--filter`, a regular expression); every one when nil.
    public var filter: String?
    /// The metrics compared (`--metric`).
    public var metrics: [String] = ["instructions", "mallocCountTotal"]
    /// Paths of the project the commit before reads too, linked into its tree (fixtures fetched into `.build`).
    public var shared: [String] = []

    public init(
        package: String = "Benchmarks",
        filter: String? = nil,
        metrics: [String] = ["instructions", "mallocCountTotal"],
        shared: [String] = []
    ) {
        self.package = package
        self.filter = filter
        self.metrics = metrics
        self.shared = shared
    }

    /// What is wrong with it, or nil.
    func problem() -> String? {
        if package.isEmpty || package.hasPrefix("/") || package.split(separator: "/").contains("..") {
            return "package must be a path inside the project"
        }
        if metrics.isEmpty { return "metrics cannot be empty" }
        if shared.contains(where: { $0.isEmpty || $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }) {
            return "shared paths must be inside the project"
        }
        return nil
    }

    /// The commit compared with: the run's base when there is one (not a new branch's zeros), else `HEAD^`.
    static func base(from context: String?) -> String {
        guard let context, !context.isEmpty, !context.allSatisfy({ $0 == "0" }) else { return "HEAD^" }
        return context
    }

    /// `swift package` arguments that run the benchmarks and store them as baseline `name`.
    func recordArguments(_ name: String) -> [String] {
        [
            "swift", "package", "--package-path", package, "--allow-writing-to-package-directory", "benchmark",
            "baseline",
            "update", name, "--no-progress"
        ]
            + (filter.map { ["--filter", $0] } ?? []) + metrics.flatMap { ["--metric", $0] }
    }

    /// `swift package` arguments that compare two stored baselines: `compare` reports, `check` judges.
    func comparisonArguments(_ verb: String, base: String, head: String, markdown: Bool = false) -> [String] {
        ["swift", "package", "--package-path", package, "benchmark", "baseline", verb, base, head, "--no-progress"]
            + (markdown ? ["--format", "markdown"] : [])
    }

    public enum Verdict: Equatable, Sendable {
        case equal
        case improved
        case regressed
        case failed(String)

        public var passed: Bool { self == .equal || self == .improved }
    }

    /// What `baseline check` said. The plugin reports both a regression and an improvement as an error, so the exit
    /// status alone cannot tell them apart; its message does.
    static func verdict(status: Int32, output: String) -> Verdict {
        if status == 0 { return .equal }
        if output.contains("benchmarkThresholdRegression") { return .regressed }
        if output.contains("benchmarkThresholdImprovement") { return .improved }
        let tail = output.split(separator: "\n").suffix(5).joined(separator: "\n")
        return .failed("baseline check exited with \(status): \(tail)")
    }
}
