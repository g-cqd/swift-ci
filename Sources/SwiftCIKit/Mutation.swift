/// Mutation testing with the pinned litmus, as a command of its own (`"mutation": {…}`), for a schedule rather than every
/// change: a run takes from minutes to hours. The run fails on a survivor that `.ci/baselines/litmus.json` does not
/// accept, or on any survivor without one, as the local gate does. litmus ships for macOS on Apple silicon only, so the
/// command runs on macOS.
public struct Mutation: Codable, Sendable, Equatable {
    /// Globs of the sources to mutate (`--only-path`); empty mutates every source litmus plans.
    public var paths: [String] = []
    /// Seconds after which litmus starts no new mutant (`--budget`); the mutants it did not test are reported.
    public var budget: Int?
    /// `copy` (litmus's default: a fresh copy of the project) or `in-place`: the checkout itself is mutated, its originals
    /// restored after each batch, so the tests find what earlier steps left in it (fetched fixtures in `.build`). Meant
    /// for a CI runner's disposable checkout, never for a working tree being edited.
    public var workspace: Workspace = .copy

    public enum Workspace: String, Codable, Sendable {
        case copy
        case inPlace = "in-place"
    }

    public init(paths: [String] = [], budget: Int? = nil, workspace: Workspace = .copy) {
        self.paths = paths
        self.budget = budget
        self.workspace = workspace
    }

    /// What is wrong with it, or nil.
    func problem() -> String? {
        if let budget, budget <= 0 { return "budget must be a positive number of seconds" }
        if paths.contains(where: \.isEmpty) { return "paths cannot hold an empty glob" }
        return nil
    }

    /// `litmus run`'s arguments, writing to `output` (a new directory outside the project).
    func runArguments(output: String) -> [String] {
        ["run", ".", "--trust-project", "--workspace", workspace.rawValue] + paths.flatMap { ["--only-path", $0] }
            + (budget.map { ["--budget", String($0)] } ?? []) + ["--output", output]
    }

    /// `litmus analyze`'s arguments over that run: only a new survivor fails when a baseline exists, every survivor otherwise.
    static func verdictArguments(output: String, baseline: String?) -> [String] {
        ["analyze", ".", "--results", output + "/run.pb"]
            + (baseline.map { ["--baseline", $0, "--gate", "new-survivors"] } ?? ["--strict"])
    }
}
