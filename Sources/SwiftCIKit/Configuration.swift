public import Foundation

/// Where swift-ci reads a project: `.ci/`, which also holds what the CI needs beside it (a tool lock, baselines, the
/// scripts of `commands`). Formatter configurations stay at the root, where editors and the tools find them.
public enum CIFolder {
    public static let path = ".ci"
    /// The configuration.
    public static let configuration = ".ci/action.json"
    /// A tool lock replacing the built-in one, used when present (``ToolLock``).
    public static let toolLock = ".ci/tools.lock.json"
    /// The baseline of an analyzer, preferred to the root `.<tool>-baseline.json` the tools write by default.
    public static func baseline(of tool: String) -> String { ".ci/baselines/\(tool).json" }
}

/// A project's `.ci/action.json`. Every key is optional: an empty object is a valid configuration of a Swift package,
/// tested on Linux and macOS on every change, with the heavy checks nightly. An unknown key is an error, so a typo
/// cannot silently turn a check off.
public struct Configuration: Codable, Sendable, Equatable {
    public var project = Project()
    public var swift = Toolchain()
    public var runners = Runners()
    /// Cadence overrides by check id (``CheckID``): the triggers it runs on. An empty list turns a check off.
    public var checks: [String: [Trigger]] = [:]
    /// Apple platforms built nightly and for a tag (`platforms` check).
    public var platforms: [Platform] = []
    public var quality = Quality()
    public var release: Release?
    public var documentation: Documentation?
    /// Project-specific steps, each a job of its own.
    public var commands: [Command] = []
    /// Skip a scheduled run when the newest commit is older than this many hours; nil disables the idle skip.
    /// Match a weekly cron with 168 rather than the default daily window of 24.
    public var scheduledMaxCommitAgeHours: Double? = 24
    /// What `swift-ci local` (and `.ci/swift-ci local`) runs without arguments: check or command ids; `debug` is this
    /// machine's debug tests (macos-debug on a Mac, linux-debug on Linux).
    public var localChecks: [String] = ["quality", "debug"]
    /// Paths a change can touch and still need no check (for push, pull-request and merge-queue triggers).
    public var documentationOnlyPaths: [String] = ["docs/**", "development/**", "release-notes/**", "*.md", "LICENSE"]

    public init() {}

    public struct Project: Codable, Sendable, Equatable {
        /// `auto` (a workspace, else a project, else `Package.swift`), `package` or `xcode`.
        public var kind: Kind = .auto
        /// The `.xcworkspace` or `.xcodeproj` for an Xcode project when there are several, relative to the root.
        public var xcode: String?
        /// The schemes to build and test (Xcode); for a package, the scheme of platform builds (default: all targets).
        public var schemes: [String] = []
        /// The test plan (Xcode).
        public var testPlan: String?
        /// Where tests run (Xcode), as `xcodebuild -destination` takes it.
        public var destination = "platform=macOS"
        /// Local packages of an Xcode project tested on their own with `swift test`, relative to the root.
        public var packages: [String] = []
        /// Whether the package builds on Linux (default: a package does, an Xcode project does not).
        public var linux: Bool?

        public enum Kind: String, Codable, Sendable { case auto, package, xcode }

        public init() {}
    }

    public struct Toolchain: Codable, Sendable, Equatable {
        /// Swift versions; the first is the primary one, every check runs on it. The `matrix` checks run on each.
        public var versions: [String] = ["6.4.1"]
        /// Versions run by the `matrix` checks only, whose failure does not fail the run (a nightly toolchain).
        public var advisory: [String] = []
        /// The checks that run on every version: by default the Linux debug tests.
        public var matrix: [String] = [CheckID.linuxDebug]
        /// The Linux image of a version; `{version}` is replaced.
        public var linuxImage = "swift:{version}-noble"
        /// Images of versions the template does not name, such as `nightly-main`.
        public var linuxImages: [String: String] = ["nightly-main": "swiftlang/swift:nightly-main-noble"]
        /// macOS: `xcode` uses the selected Xcode's toolchain (nothing to install); a version installs that release.
        public var macOS = "primary"
        /// The Xcode to select on macOS runners (an app path or a version such as `26.6`); nil keeps the runner's.
        public var xcode: String?
        /// Environment for every build and test (a dev flag). Set, it also adds the `consumer` check without it.
        public var environment: [String: String] = [:]
        /// Run tests in parallel.
        public var parallel = true
        /// Test-name patterns skipped only under a named sanitizer (for example an ASan stack-depth limit).
        public var sanitizerSkips: [String: [String]] = [:]
        /// Test-name patterns skipped in one build mode only: `debug`, `release`, `address` or `thread` (for example a
        /// deadline an unoptimized build misses, which the release tests still run).
        public var testSkips: [String: [String]] = [:]
        /// Extra Linux LeakSanitizer stack symbols, only for independently reproduced dependency/runtime leaks.
        public var linuxLeakSuppressions: [String] = []

        public init() {}

        /// The toolchain macOS jobs use: nil for the selected Xcode's.
        public var macOSVersion: String? {
            switch macOS {
                case "xcode": nil
                case "primary": versions.first
                default: macOS
            }
        }

        /// The Linux image of `version`.
        public func image(for version: String) -> String {
            linuxImages[version] ?? linuxImage.replacingOccurrences(of: "{version}", with: version)
        }
    }

    public struct Runners: Codable, Sendable, Equatable {
        /// Labels of the macOS runners (self-hosted ones included).
        public var macOS = ["macos-26"]
        /// Labels of the Linux runners that build and test.
        public var linux = ["ubuntu-latest"]

        public init() {}
    }

    public struct Platform: Codable, Sendable, Equatable {
        /// `iOS`, `tvOS`, `watchOS`, `visionOS`, `macCatalyst` or `macOS`.
        public var name: String
        /// An `xcodebuild -destination`; default `generic/platform=<name>`.
        public var destination: String?

        public init(name: String, destination: String? = nil) {
            self.name = name
            self.destination = destination
        }

        public var resolvedDestination: String {
            destination
                ?? (name == "macCatalyst" ? "generic/platform=macOS,variant=Mac Catalyst" : "generic/platform=\(name)")
        }
    }

    public struct Quality: Codable, Sendable, Equatable {
        /// The paths the analyzers read (default: `Sources` and `Tests` where they exist, else the root).
        public var paths: [String] = []
        /// The g-cqd analyzers run from their pinned releases, in this order.
        public var analyzers: [String] = ["deadwood", "dolly", "arcleak"]
        /// Tools run only by `swift-ci local quality`, never in CI's quality check (for now: `litmus`, mutation testing,
        /// which takes minutes; a scheduled `mutation` command, ``Mutation``, runs it in CI). Opt-in: none by default, so the default local gate stays fast. With `.ci/baselines/litmus.json`
        /// only a new surviving mutant fails; without one, every survivor does.
        public var local: [String] = []
        /// Formatters and linters: `auto` runs the ones whose configuration file is at the root
        /// (`.swift-format`, `.swiftlint.yml`, `.swiftformat`); a list runs exactly those.
        public var formatters: Formatters = .auto
        /// A tool lock replacing the built-in one (``ToolLock``), relative to the root; `.ci/tools.lock.json` is used
        /// without being named.
        public var lock: String?
        /// The Swift files swift-format checks (globs, relative to the root), before `exclude`. Default: a package's
        /// layout (its root `Package.swift`, `Sources`, `Tests`, `Plugins`; not benchmarks, examples' manifests or
        /// research code); everything for
        /// an Xcode project, whose layout is its own.
        public var include: [String]?

        /// `include`, or the default for `project`.
        public func formatted(for project: SwiftCIKit.Project) -> [String] {
            include ?? (project.isXcode ? ["**"] : ["/Package.swift", "Sources/**", "Tests/**", "Plugins/**"])
        }
        /// Rules beyond formatting for a shipped library (``Discipline``); nil (the default) runs none.
        public var discipline: Discipline?
        /// Files the formatters skip (fixtures written to be badly formatted, generated code).
        public var exclude: [String] = ["**/Fixtures/**", "**/Generated/**", ".build/**"]

        public init() {}

        public enum Formatters: Codable, Sendable, Equatable {
            case auto
            case only([Formatter])

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let word = try? container.decode(String.self) {
                    guard word == "auto" else {
                        throw SwiftCIError("quality.formatters: 'auto' or a list, not '\(word)'")
                    }
                    self = .auto
                } else {
                    self = .only(try container.decode([Formatter].self))
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                    case .auto: try container.encode("auto")
                    case .only(let list): try container.encode(list)
                }
            }
        }
    }

    public struct Release: Codable, Sendable, Equatable {
        /// The executables archived for a tag, each checked to print the tag's version for `--version`.
        public var executables: [String] = []
        /// The release note of a tag; `{tag}` is replaced. Linted, and its Archives section filled (``ReleaseNote``).
        public var notes = "release-notes/{tag}.md"

        public init() {}
    }

    public struct Documentation: Codable, Sendable, Equatable {
        /// Targets (package) or schemes (Xcode) to document.
        public var targets: [String]
        /// Fail on a broken link or an undocumented symbol DocC reports.
        public var warningsAsErrors = true

        public init(targets: [String]) {
            self.targets = targets
        }
    }

    public struct Command: Codable, Sendable, Equatable {
        public var id: String
        /// Human-readable Actions label; id remains the stable CLI/configuration key.
        public var title: String?
        /// A shell command, run from the root.
        public var run: String
        /// TLA+ models checked with TLC instead of a shell command (``TLAModels``).
        public var tla: TLAModels?
        /// Repositories fetched at pinned commits instead of a shell command (``GitFixture``).
        public var git: [GitFixture]?
        /// Mutation testing with the pinned litmus instead of a shell command (``Mutation``).
        public var mutation: Mutation?
        public var os: OS = .linux
        public var cadence: [Trigger] = Array(Trigger.everyChange).sorted()
        /// What it writes to `.build/swift-ci/dist` is uploaded, and published with a tag's release (an extra
        /// archive, such as a bundle with a model).
        public var archives = false
        /// A check (or command) this one runs at the end of, in its job and on its warm tree, instead of in a job of
        /// its own; it then runs where and when that check does (`os` and `cadence` do not apply).
        public var after: String?
        /// Run before each named check on its runner (fixture downloads or generation). No standalone job.
        /// Cannot be combined with `after`; os and cadence come from the host checks.
        public var before: [String] = []

        public init(
            id: String,
            run: String,
            os: OS = .linux,
            cadence: [Trigger] = Array(Trigger.everyChange).sorted(),
            archives: Bool = false,
            after: String? = nil,
            before: [String] = [],
            title: String? = nil,
            tla: TLAModels? = nil,
            git: [GitFixture]? = nil,
            mutation: Mutation? = nil
        ) {
            self.id = id
            self.title = title
            self.run = run
            self.tla = tla
            self.git = git
            self.mutation = mutation
            self.os = os
            self.cadence = cadence
            self.archives = archives
            self.after = after
            self.before = before
        }
    }
}

/// An operating system of runners.
public enum OS: String, Codable, Sendable, Hashable {
    case linux, macOS
}

/// A formatter or linter.
public enum Formatter: String, Codable, Sendable, CaseIterable {
    /// swift-format (`swift format`), configured by `.swift-format`.
    case swiftFormat = "swift-format"
    /// SwiftLint, configured by `.swiftlint.yml`.
    case swiftLint = "swiftlint"
    /// SwiftFormat (nicklockwood), configured by `.swiftformat`.
    case nickSwiftFormat = "swiftformat"

    /// The configuration file that turns it on under `auto`.
    public var configurationFile: String {
        switch self {
            case .swiftFormat: ".swift-format"
            case .swiftLint: ".swiftlint.yml"
            case .nickSwiftFormat: ".swiftformat"
        }
    }
}

// MARK: - Strict decoding

extension Configuration {
    /// Reads the configuration's text (`file` names it in errors). An unknown key or a wrong type is an error naming its path. Missing keys take
    /// their defaults: the text is merged onto the encoded defaults, then decoded.
    public static func decode(_ data: Data, file: String = CIFolder.configuration) throws -> Configuration {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            try StrictKeys.check(object, against: try Defaults.encode(Defaults.sample()), path: "", file: file)
            let merged = Defaults.merge(object, onto: try Defaults.template())
            let configuration = try JSONDecoder()
                .decode(Configuration.self, from: try JSONSerialization.data(withJSONObject: merged))
            guard !configuration.swift.versions.isEmpty else {
                throw SwiftCIError("\(file): swift.versions needs at least one version")
            }
            if let age = configuration.scheduledMaxCommitAgeHours, age < 0 {
                throw SwiftCIError("\(file): scheduledMaxCommitAgeHours must be nonnegative or null")
            }
            for symbol in configuration.swift.linuxLeakSuppressions {
                guard !symbol.isEmpty, symbol.allSatisfy({ $0.isLetter || $0.isNumber || "_.$".contains($0) }) else {
                    throw SwiftCIError(
                        "\(file): swift.linuxLeakSuppressions requires a symbol, not a wildcard or suppression file syntax"
                    )
                }
            }
            for sanitizer in configuration.swift.sanitizerSkips.keys where !["address", "thread"].contains(sanitizer) {
                throw SwiftCIError("\(file): swift.sanitizerSkips: unknown sanitizer '\(sanitizer)'")
            }
            for mode in configuration.swift.testSkips.keys
            where !["debug", "release", "address", "thread"].contains(mode) {
                throw SwiftCIError(
                    "\(file): swift.testSkips: unknown mode '\(mode)' (debug, release, address or thread)"
                )
            }
            return configuration
        } catch let error as SwiftCIError {
            throw error
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context),
            let DecodingError.dataCorrupted(context)
        {
            throw SwiftCIError("\(file): \(Self.path(context.codingPath))\(context.debugDescription)")
        } catch let DecodingError.keyNotFound(key, context) {
            throw SwiftCIError("\(file): \(Self.path(context.codingPath + [key]))required")
        } catch {
            throw SwiftCIError("\(file): \(error.localizedDescription)")
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        let path = keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().drop { $0 == "." }
        return path.isEmpty ? "" : path + ": "
    }

    /// The configuration at `root`, or the defaults when there is none.
    public static func load(root: URL, file: String = CIFolder.configuration) throws -> Configuration {
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : root.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        return try decode(try Data(contentsOf: url), file: file)
    }
}

/// The defaults every key of the configuration falls back to, as JSON: the encoded default configuration, and templates
/// used only when a key is given: `name?` for an optional section, `name[]` for each element of a list.
enum Defaults {
    static func encode(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }

    static func template() throws -> [String: Any] {
        var root = try encode(Configuration())
        root["release?"] = try encode(Configuration.Release())
        root["documentation?"] = ["warningsAsErrors": true]
        var command = try encode(Configuration.Command(id: "", run: ""))
        command["tla?"] = try encode(TLAModels())
        command["git?"] = try [encode(GitFixture(git: "", commit: "", into: ""))]
        command["mutation?"] = try encode(Mutation())
        root["commands[]"] = command
        var quality = root["quality"] as? [String: Any] ?? [:]
        quality["discipline?"] = try encode(Discipline())
        root["quality"] = quality
        return root
    }

    /// A configuration with every optional set and one element in every list: its keys are all the model's.
    static func sample() -> Configuration {
        var sample = Configuration()
        sample.project.xcode = ""
        sample.project.testPlan = ""
        sample.project.linux = true
        sample.swift.xcode = ""
        sample.quality.lock = ""
        sample.quality.include = []
        sample.quality.local = [""]
        sample.quality.discipline = Discipline()
        sample.release = Configuration.Release()
        sample.documentation = Configuration.Documentation(targets: [])
        sample.commands = [
            Configuration.Command(
                id: "",
                run: "",
                after: "",
                before: [],
                title: "",
                tla: TLAModels(),
                git: [GitFixture(git: "", commit: "", into: "")],
                mutation: Mutation(paths: [""], budget: 0)
            )
        ]
        sample.platforms = [Configuration.Platform(name: "", destination: "")]
        return sample
    }

    /// `value` with every key it lacks taken from `defaults`, recursively.
    static func merge(_ value: Any, onto defaults: Any?) -> Any {
        guard let object = value as? [String: Any] else { return value }
        let base = defaults as? [String: Any] ?? [:]
        var result = base.filter { !$0.key.hasSuffix("?") && !$0.key.hasSuffix("[]") }
        for (key, child) in object {
            if let list = child as? [Any], let element = base[key + "[]"] {
                result[key] = list.map { merge($0, onto: element) }
            } else {
                result[key] = merge(child, onto: base[key] ?? base[key + "?"])
            }
        }
        return result
    }
}

/// Rejects keys the model does not have: an object may hold the keys of ``Defaults/sample()``, a configuration with
/// every optional set, so the accepted keys are always exactly the model's.
enum StrictKeys {
    /// Maps whose keys are the user's.
    static let freeKeys: Set<String> = [
        "checks", "swift.environment", "swift.linuxImages", "swift.sanitizerSkips", "swift.testSkips"
    ]

    static func check(_ value: Any, against sample: Any, path: String, file: String) throws {
        if freeKeys.contains(path) { return }
        if let object = value as? [String: Any], let keys = sample as? [String: Any] {
            for (key, child) in object.sorted(by: { $0.key < $1.key }) where !(path.isEmpty && key == "$schema") {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                guard let schema = keys[key] else {
                    let known = keys.keys.sorted().joined(separator: ", ")
                    throw SwiftCIError("\(file): unknown key '\(childPath)' (known here: \(known))")
                }
                try check(child, against: schema, path: childPath, file: file)
            }
        } else if let array = value as? [Any], let element = (sample as? [Any])?.first {
            for (index, child) in array.enumerated() {
                try check(child, against: element, path: "\(path)[\(index)]", file: file)
            }
        }
        // Anything else is a value: the decoder reports a wrong type.
    }
}
