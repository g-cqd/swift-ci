public import Foundation

/// Rules beyond formatting for a library that ships: no force unwrap or `try!` in its shipped targets, no
/// locale-sensitive `strtod`, and test-tree hygiene. A port of aemi's `swift package lint` rules into the CLI, so a
/// project's gate is its `.ci/action.json` and runs the same in CI and locally, with no plugin to resolve.
///
/// A reviewed exception opts out per line: `// lint:allow` for the textual rules, `// swift-format-ignore:
/// NeverForceUnwrap` (or `NeverUseForceTry`) for the AST ones.
public struct Discipline: Codable, Sendable, Equatable {
    /// The shipped library targets' directories, relative to the root. Tests, plugins, macros and tools are not.
    public var shipped: [String] = ["Sources"]
    /// swift-format's `NeverForceUnwrap` and `NeverUseForceTry` over `shipped`, on top of the project's
    /// `.swift-format`. Only those two rules' findings count: formatting is quality's swift-format step.
    public var forceUnwrap = true
    /// The textual rules that apply.
    public var rules: [Rule] = Rule.allCases

    public init() {}

    public enum Rule: String, Codable, Sendable, CaseIterable {
        /// `strtod(` in shipped code: it reads the C locale's decimal separator.
        case strtod
        /// A hand-rolled `struct SplitMix64` or `struct LCG` in the tests: use the test kit's seeded generator.
        case inlinePRNG = "inline-prng"
        /// `#expect(throws: (any Error).self)` or `Error.self` in the tests: name the concrete error.
        case untypedThrows = "untyped-throws"
        /// An `#expect` or `#require` over a clock in the tests: assert counts, not elapsed time.
        case wallClock = "wall-clock"
    }

    /// One violation.
    public struct Finding: Sendable, Equatable, CustomStringConvertible {
        public var path: String
        public var line: Int
        public var rule: Rule
        public var description: String { "\(path):\(line): [\(rule.rawValue)] \(rule.message) (// lint:allow)" }
    }

    /// The textual findings of the files under `root`.
    public func scan(root: URL) -> [Finding] {
        var findings: [Finding] = []
        let shippedRules = rules.filter { $0 == .strtod }
        let testRules = rules.filter { $0 != .strtod }
        for directory in shipped where !shippedRules.isEmpty {
            findings += Self.scan(root: root, directory: directory, rules: shippedRules)
        }
        if !testRules.isEmpty { findings += Self.scan(root: root, directory: "Tests", rules: testRules) }
        return findings.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    /// The project's `.swift-format` with the force-unwrap rules on, for `swift format lint --configuration`.
    public static func strictConfiguration(from data: Data) throws -> Data {
        try SwiftFormatLint.rewritingRules(of: data) { rules in
            for rule in forceUnwrapRules { rules[rule] = true }
        }
    }

    /// The rules the force-unwrap check is about.
    public static let forceUnwrapRules = ["NeverForceUnwrap", "NeverUseForceTry"]

    /// What a `swift format lint` run with the strict configuration says about force unwraps.
    public enum ForceUnwrapVerdict: Equatable, Sendable {
        case clean
        /// The diagnostics of the force-unwrap rules, as swift-format printed them.
        case findings([String])
        /// The linter failed with no diagnostic at all (a crash, an unreadable file): nothing was checked.
        case failed(String)
    }

    /// The force-unwrap rules' diagnostics in `output`. Others (whitespace, the project's own rules) are
    /// quality's swift-format step's, so they neither print nor fail here; a failure with no diagnostic is the
    /// linter's own.
    public static func forceUnwrapVerdict(status: Int32, output: String) -> ForceUnwrapVerdict {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let unwraps = lines.filter { line in forceUnwrapRules.contains { line.contains("[\($0)]") } }
        if !unwraps.isEmpty { return .findings(unwraps) }
        guard status != 0 else { return .clean }
        let diagnostic = lines.contains {
            $0.range(of: #": (error|warning): \[[A-Za-z]+\]"#, options: .regularExpression) != nil
        }
        return diagnostic ? .clean : .failed("exit status \(status)")
    }

    static func scan(root: URL, directory: String, rules: [Rule]) -> [Finding] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var findings: [Finding] = []
        while let file = walker.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            // Both resolved: the enumerator may report /private/var for a /var base (macOS temporary files).
            let prefix = base.resolvingSymlinksInPath().path + "/"
            let full = file.resolvingSymlinksInPath().path
            guard full.hasPrefix(prefix) else { continue }
            let path = directory + "/" + full.dropFirst(prefix.count)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.contains("lint:allow") {
                for rule in rules where rule.matches(line) {
                    findings.append(Finding(path: path, line: offset + 1, rule: rule))
                }
            }
        }
        return findings
    }
}

extension Discipline.Rule {
    func matches(_ line: Substring) -> Bool {
        switch self {
            case .strtod: line.contains("strtod(")
            case .inlinePRNG: line.contains("struct SplitMix64") || line.contains("struct LCG")
            case .untypedThrows:
                line.contains("#expect(throws: (any Error).self)") || line.contains("#expect(throws: Error.self)")
            case .wallClock:
                (line.contains("#expect(") || line.contains("#require("))
                    && [
                        "DispatchTime", "ContinuousClock", "SuspendingClock", ".timeIntervalSince", ".uptimeNanoseconds"
                    ]
                    .contains { line.contains($0) }
        }
    }

    var message: String {
        switch self {
            case .strtod: "locale-sensitive strtod in shipped library code"
            case .inlinePRNG: "an inline PRNG in the tests: use the test kit's seeded generator"
            case .untypedThrows: "an untyped #expect(throws:): name the concrete error"
            case .wallClock: "a wall-clock assertion: assert allocations or operation counts instead"
        }
    }
}
