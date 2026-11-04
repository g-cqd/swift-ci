import Foundation

/// TLA+ models checked with TLC: every `<Module>.cfg` beside `<Module>.tla` in a directory must hold, and every
/// `<Module>.buggy.cfg` must be refuted (a control: it keeps a broken design on record and shows the checker can
/// fail, so the green run of its twin means something). TLC is the pinned `tla2tools.jar`, run with Java.
///
/// Each run gets a state directory of its own outside the repository: by default TLC names it after the current
/// second, beside the specification, and aborts when it exists, so a model that ends within a second made the next
/// one fail, and every refuted model left a directory in the tree.
public struct TLAModels: Codable, Sendable, Equatable {
    /// The directory of the specifications and their `.cfg` files, relative to the root.
    public var models: String = "docs/formal"

    public init(models: String = "docs/formal") {
        self.models = models
    }
}

public enum TLC {
    public static let version = "1.7.4"
    public static let sha256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
    public static var url: String {
        "https://github.com/tlaplus/tlaplus/releases/download/v\(version)/tla2tools.jar"
    }

    /// Where Java is looked for, in order.
    public static func javaCandidates(javaHome: String?) -> [String] {
        (javaHome.map { ["\($0)/bin/java"] } ?? [])
            + ["java", "/opt/homebrew/opt/openjdk/bin/java", "/usr/local/opt/openjdk/bin/java"]
    }

    /// One model: a `.cfg` file and the module it checks.
    public struct Model: Sendable, Equatable {
        /// The configuration's name without `.cfg`: `LineSplitter`, `LineSplitter.buggy`.
        public var name: String
        /// The specification's module: the name without `.buggy`.
        public var module: String
        public var mustFail: Bool { name != module }
    }

    /// The models of the `.cfg` file names, in name order.
    public static func models(_ files: [String]) -> [Model] {
        files.filter { $0.hasSuffix(".cfg") }.sorted()
            .map { file in
                let name = String(file.dropLast(".cfg".count))
                let module = name.hasSuffix(".buggy") ? String(name.dropLast(".buggy".count)) : name
                return Model(name: name, module: module)
            }
    }

    /// The command line of one run, from the models' directory.
    public static func arguments(java: String, jar: String, model: Model, states: String) -> [String] {
        [
            java, "-XX:+UseParallelGC", "-cp", jar, "tlc2.TLC", "-config", "\(model.name).cfg", "-metadir", states,
            "-workers", "auto", "-cleanup", "\(model.module).tla"
        ]
    }

    public enum Verdict: Sendable, Equatable {
        /// The model holds (TLC's states line, when it printed one).
        case held(String)
        /// A control is refuted, as it must be (TLC's error line).
        case refutedAsItMust(String)
        case failed(String)

        public var passed: Bool {
            if case .failed = self { false } else { true }
        }
    }

    /// TLC's verdict lines for a model that is wrong, as opposed to a run that failed (a parse error, a crash).
    static let violations = [
        #"^Error: Invariant \S+ is violated"#, #"^Error: The invariant of \S+ is equal to FALSE"#,
        #"^Error: Deadlock reached"#, #"^Error: Temporal properties were violated"#,
        #"^Error: Action property \S+ is violated"#, #"^Error: The following assertion failed"#,
        #"^Error: Assumption .* is false"#
    ]

    /// What one run says. TLC exits 10 to 14 for a violation, but with 151 for an invariant that is false in the
    /// initial state, so the verdict is read from its error line.
    public static func verdict(mustFail: Bool, status: Int32, output: String) -> Verdict {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let violation = lines.first { line in
            violations.contains { line.range(of: $0, options: .regularExpression) != nil }
        }
        let error = lines.first { $0.hasPrefix("Error:") }
        switch (mustFail, status, violation) {
            case (false, 0, _):
                return .held(lines.first { $0.contains("distinct states found") } ?? "no error found")
            case (false, _, let violation?):
                return .failed(violation)
            case (true, 0, _):
                return .failed("a control must be refuted and TLC found no error")
            case (true, _, let violation?):
                return .refutedAsItMust(violation)
            case (_, _, nil):
                return .failed("TLC failed (exit status \(status)): \(error ?? lines.last ?? "no output")")
        }
    }
}
