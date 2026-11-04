import Foundation

/// A program and its arguments, run from the project root.
public struct ShellCommand: Codable, Sendable, Equatable, CustomStringConvertible {
    public var title: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(_ title: String, _ arguments: [String], environment: [String: String] = [:]) {
        self.title = title
        self.arguments = arguments
        self.environment = environment
    }

    public var description: String {
        let words = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + arguments.map(Self.quote)
        return words.joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        let plain = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:,@+%".contains($0) }
        return plain && !word.isEmpty ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One step of a job, executed in order by ``Executor``; the first failure stops the job.
public enum Step: Sendable, Equatable {
    case run(ShellCommand)
    /// A project's own shell command (`commands`).
    case shell(title: String, script: String)
    /// Downloads a locked tool if it is not installed, checks its hash and version.
    case install(ToolLock.Tool)
    /// Runs an installed tool.
    case tool(name: String, title: String, arguments: [String])
    /// Packages a release-built executable into `.build/swift-ci/dist`, checking its `--version` against the tag.
    case archive(executable: String, os: OS)
    /// Writes a file the next steps read, relative to the root.
    case file(path: String, contents: String)
    /// The shipped-library and test-tree rules (``Discipline``).
    case discipline(Discipline)

    public var title: String {
        switch self {
            case .run(let command): command.title
            case .shell(let title, _): title
            case .install(let tool): "Install \(tool.name) \(tool.version)"
            case .tool(_, let title, _): title
            case .archive(let executable, _): "Archive \(executable)"
            case .file(let path, _): "Write \(path)"
            case .discipline: "Discipline · Shipped Code & Tests"
        }
    }
}

/// Where swift-ci writes: derived data, result bundles, documentation, archives. Inside `.build`, which every project
/// ignores already.
public enum Paths {
    public static let root = ".build/swift-ci"
    public static let derivedData = root + "/DerivedData"
    public static let results = root + "/results"
    public static let documentation = root + "/docs"
    public static let distribution = root + "/dist"
    /// LeakSanitizer suppressions of the Linux AddressSanitizer runs.
    public static let leakSuppressions = root + "/lsan-suppressions.txt"
}

/// What LeakSanitizer must not report on Linux, each seen on swift:6.4.1-noble and not the project's:
/// - the XCTest runner `swift test` starts after swift-testing keeps its suites until exit (432 bytes in 7 objects,
///   all from `XCTMainMisc`);
/// - Foundation's `Process.run()` keeps one weak reference for the life of the process (32 bytes, once, however many
///   processes run);
/// - FoundationEssentials leaks its read buffer when reading an empty file (4 KiB per read). See
///   `.ci/probes/EmptyFileRead.swift` for the standalone reproduction. This suppression covers allocations in
///   that Foundation file-reading function, not arbitrary Data or project allocations.
/// A leak allocated anywhere else is still reported.
public let leakSuppressions = """
    # swift-ci: the XCTest runner's objects live until exit.
    leak:libXCTest.so
    # swift-ci: Foundation's Process keeps one weak reference for the life of the process.
    leak:Foundation7ProcessC3run
    # swift-ci: Swift 6.4.1 Foundation leaks the read buffer for an empty file.
    leak:FoundationEssentials17readBytesFromFile

    """

/// The steps of each check, for one project.
public struct StepPlanner: Sendable {
    public var configuration: Configuration
    public var project: Project
    public var lock: ToolLock
    /// The project's absolute path, for what a child process reads from another directory (the leak suppressions);
    /// empty keeps paths relative.
    public var root: String
    /// Where a local mutation run writes: a new directory outside the project, as litmus requires (it refuses an
    /// output inside the source root or one that exists).
    public var mutationOutput: String

    public init(
        configuration: Configuration,
        project: Project,
        lock: ToolLock,
        root: String = "",
        mutationOutput: String? = nil
    ) {
        self.configuration = configuration
        self.project = project
        self.lock = lock
        self.root = root
        self.mutationOutput =
            mutationOutput
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("swift-ci-litmus-\(UUID().uuidString)")
            .path
    }

    /// A pinned tool: its install, then one run of it.
    func locked(_ name: String, title: String, _ arguments: [String]) throws -> [Step] {
        [.install(try lock.tool(named: name)), .tool(name: name, title: title, arguments: arguments)]
    }

    /// `path` from the root, absolute when the root is known.
    func absolute(_ path: String) -> String {
        root.isEmpty ? path : (root.hasSuffix("/") ? root : root + "/") + path
    }

    /// The steps of check (or command) `id`.
    /// - Parameters:
    ///   - id: a check (``CheckID``) or a command of the configuration.
    ///   - swiftFiles: the repository's Swift files, for swift-format.
    ///   - fileExists: whether a root-relative path exists (baselines).
    ///   - local: a developer's run: adds the tools quality runs only locally.
    /// - Returns: the steps, in order.
    /// - Throws: ``SwiftCIError`` for an unknown id, or a check the project cannot run.
    public func steps(
        for id: String,
        swiftFiles: [String] = [],
        fileExists: (String) -> Bool = { _ in false },
        local: Bool = false
    ) throws -> [Step] {
        let before = configuration.commands.filter { $0.before.contains(id) }
            .map { Step.shell(title: $0.title ?? $0.id, script: $0.run) }
        // The commands that run at the end of this one's job.
        let after = configuration.commands.filter { $0.after == id }
            .map { Step.shell(title: $0.title ?? $0.id, script: $0.run) }
        return try before + own(id, swiftFiles: swiftFiles, fileExists: fileExists, local: local) + after
    }

    func own(_ id: String, swiftFiles: [String], fileExists: (String) -> Bool, local: Bool) throws -> [Step] {
        if let command = configuration.commands.first(where: { $0.id == id }) {
            return [.shell(title: command.title ?? command.id, script: command.run)]
        }
        switch id {
            case CheckID.quality: return try quality(swiftFiles: swiftFiles, fileExists: fileExists, local: local)
            case CheckID.linuxDebug: return package(.debug)
            case CheckID.linuxRelease: return package(.release)
            case CheckID.linuxAddress:
                return [
                    .file(
                        path: Paths.leakSuppressions,
                        contents: leakSuppressions
                            + configuration.swift.linuxLeakSuppressions.map { "leak:\($0)\n" }.joined()
                    )
                ]
                    + package(
                        .sanitizer("address"),
                        extraEnvironment: ["LSAN_OPTIONS": "suppressions=\(absolute(Paths.leakSuppressions))"]
                    )
            case CheckID.linuxThread: return package(.sanitizer("thread"))
            case CheckID.consumer: return package(.debug, environment: [:])
            case CheckID.macOSDebug: return project.isXcode ? try xcode(.debug) : package(.debug, coverage: true)
            case CheckID.macOSRelease: return project.isXcode ? try xcode(.release) : package(.release)
            case CheckID.macOSAddress:
                return project.isXcode ? try xcode(.sanitizer("address")) : package(.sanitizer("address"))
            case CheckID.macOSThread:
                return project.isXcode ? try xcode(.sanitizer("thread")) : package(.sanitizer("thread"))
            case CheckID.platforms: return try platforms()
            case CheckID.documentation: return try documentation()
            case CheckID.archiveLinux: return try archive(os: .linux)
            case CheckID.archiveMacOS: return try archive(os: .macOS)
            default: throw SwiftCIError("no check or command '\(id)'")
        }
    }

    enum Mode: Equatable {
        case debug, release
        case sanitizer(String)
    }

    // MARK: Swift packages

    /// Builds the tests once, then runs them without building: in release, `-enable-testing` makes the build the one
    /// `swift test` needs (without it, `swift test -c release` rebuilds everything after `swift build -c release`).
    func package(
        _ mode: Mode,
        coverage: Bool = false,
        environment: [String: String]? = nil,
        extraEnvironment: [String: String] = [:],
        path: String? = nil
    ) -> [Step] {
        let environment = (environment ?? configuration.swift.environment).merging(extraEnvironment) { $1 }
        var build = ["swift", "build", "--build-tests"]
        var test = ["swift", "test", "--skip-build"]
        if let path {
            build += ["--package-path", path]
            test += ["--package-path", path]
        }
        let label: String
        let skips: [String]
        switch mode {
            case .debug:
                label = "debug"
                skips = configuration.swift.testSkips["debug"] ?? []
            case .release:
                label = "release"
                build += ["-c", "release", "-Xswiftc", "-enable-testing"]
                test += ["-c", "release"]
                skips = configuration.swift.testSkips["release"] ?? []
            case .sanitizer(let sanitizer):
                label = "\(sanitizer) sanitizer"
                build += ["--sanitize=\(sanitizer)"]
                test += ["--sanitize=\(sanitizer)"]
                skips =
                    (configuration.swift.sanitizerSkips[sanitizer] ?? [])
                    + (configuration.swift.testSkips[sanitizer] ?? [])
        }
        for pattern in skips {
            test += ["--skip", pattern]
        }
        if coverage {
            build += ["--enable-code-coverage"]
            test += ["--enable-code-coverage"]
        }
        if !configuration.swift.parallel { test += ["--no-parallel"] }
        let place = path.map { " (\($0))" } ?? ""
        return [
            .run(ShellCommand("Build the tests, \(label)\(place)", build, environment: environment)),
            .run(ShellCommand("Test, \(label)\(place)", test, environment: environment))
        ]
    }

    // MARK: Xcode projects

    func xcodeBase(scheme: String, destination: String) throws -> [String] {
        guard let xcode = project.xcode else { throw SwiftCIError("not an Xcode project") }
        var arguments = [
            "xcodebuild", project.kind == .xcodeWorkspace ? "-workspace" : "-project", xcode, "-scheme", scheme
        ]
        arguments += ["-destination", destination, "-derivedDataPath", Paths.derivedData]
        return arguments
    }

    /// `build-for-testing` once, then `test-without-building` with a result bundle per scheme; then the local packages.
    func xcode(_ mode: Mode) throws -> [Step] {
        let settings = configuration.project
        var steps: [Step] = []
        for scheme in settings.schemes {
            var base = try xcodeBase(scheme: scheme, destination: settings.destination)
            if let plan = settings.testPlan { base += ["-testPlan", plan] }
            var extra: [String] = []
            let label: String
            switch mode {
                case .debug:
                    label = "debug"
                    extra = ["-enableCodeCoverage", "YES"]
                case .release:
                    label = "release"
                    extra = ["-configuration", "Release"]
                case .sanitizer(let sanitizer):
                    label = "\(sanitizer) sanitizer"
                    extra = [sanitizer == "thread" ? "-enableThreadSanitizer" : "-enableAddressSanitizer", "YES"]
            }
            let bundle = "\(Paths.results)/\(scheme)-\(label.replacingOccurrences(of: " ", with: "-")).xcresult"
            steps.append(
                .run(
                    ShellCommand(
                        "Build \(scheme) for testing, \(label)",
                        [base[0], "build-for-testing"] + base.dropFirst() + extra
                    )
                )
            )
            steps.append(
                .run(
                    ShellCommand(
                        "Test \(scheme), \(label)",
                        [base[0], "test-without-building"] + base.dropFirst() + extra + ["-resultBundlePath", bundle]
                    )
                )
            )
        }
        for path in settings.packages {
            steps += package(mode, coverage: mode == .debug, path: path)
        }
        return steps
    }

    // MARK: Platforms, documentation, archives

    /// A platform build compiles and links, unsigned (a generic destination has no device to sign for). Packages'
    /// macros and plugins run without the interactive trust prompt. And dependencies keep their warnings: Xcode builds
    /// them with `-suppress-warnings`, which the driver rejects beside the `-warnings-as-errors` of a dependency that
    /// declares `treatAllWarnings(as: .error)`, as the family's packages do ("conflicting options").
    static let platformBuildSettings = [
        "-skipPackagePluginValidation", "-skipMacroValidation", "CODE_SIGNING_ALLOWED=NO", "SWIFT_SUPPRESS_WARNINGS=NO"
    ]

    /// Every platform with `xcodebuild build`, which knows the SDKs (a package's schemes are its products, and
    /// `<Package>-Package` builds every target).
    func platforms() throws -> [Step] {
        let schemes = configuration.project.schemes
        guard !schemes.isEmpty else {
            throw SwiftCIError("platforms needs project.schemes (for a package, '<name>-Package' builds every target)")
        }
        var steps: [Step] = []
        for platform in configuration.platforms {
            for scheme in schemes {
                var arguments = ["xcodebuild", "build", "-scheme", scheme, "-destination", platform.resolvedDestination]
                if let xcode = project.xcode {
                    arguments.insert(
                        contentsOf: [project.kind == .xcodeWorkspace ? "-workspace" : "-project", xcode],
                        at: 2
                    )
                }
                arguments += ["-derivedDataPath", Paths.derivedData] + Self.platformBuildSettings
                steps.append(.run(ShellCommand("Build \(scheme) for \(platform.name)", arguments)))
            }
        }
        return steps
    }

    func documentation() throws -> [Step] {
        guard let settings = configuration.documentation else { throw SwiftCIError("no documentation configured") }
        if project.isXcode {
            return try settings.targets.map { scheme in
                let destination = configuration.platforms.first?.resolvedDestination ?? "generic/platform=macOS"
                var arguments = try xcodeBase(scheme: scheme, destination: destination)
                arguments.insert("docbuild", at: 1)
                if settings.warningsAsErrors { arguments += ["OTHER_DOCC_FLAGS=--warnings-as-errors"] }
                return .run(ShellCommand("Documentation of \(scheme)", arguments))
            }
        }
        // The package must depend on swift-docc-plugin, which provides `generate-documentation`.
        var arguments = [
            "swift", "package", "--allow-writing-to-directory", Paths.documentation, "generate-documentation"
        ]
        for target in settings.targets { arguments += ["--target", target] }
        if settings.targets.count > 1 { arguments += ["--enable-experimental-combined-documentation"] }
        arguments += ["--output-path", Paths.documentation]
        if settings.warningsAsErrors { arguments += ["--warnings-as-errors"] }
        return [.run(ShellCommand("Documentation", arguments, environment: configuration.swift.environment))]
    }

    func archive(os: OS) throws -> [Step] {
        guard let executables = configuration.release?.executables, !executables.isEmpty else {
            throw SwiftCIError("no release.executables to archive")
        }
        guard !project.isXcode else { throw SwiftCIError("archives of an Xcode project are not supported yet") }
        return executables.flatMap { executable in
            [
                .run(
                    ShellCommand(
                        "Build \(executable), release",
                        ["swift", "build", "-c", "release", "--product", executable]
                            + (os == .linux ? ["-Xlinker", "-rpath", "-Xlinker", "$ORIGIN"] : [])
                    )
                ),
                .archive(executable: executable, os: os)
            ]
        }
    }

    // MARK: Quality

    /// Each analyzer writes its current findings to `.ci/baselines/<tool>.json`: they are accepted, and only a finding
    /// not in the baseline fails quality afterwards. For adopting a gate on a codebase with a backlog.
    public func baselines() throws -> [Step] {
        var steps = try configuration.quality.analyzers.flatMap { name -> [Step] in
            let tool = try lock.tool(named: name)
            guard let base = tool.arguments else { throw SwiftCIError("\(name) is a formatter, not an analyzer") }
            let arguments = base + ["--write-baseline", CIFolder.baseline(of: name)] + project.corpus
            return [.install(tool), .tool(name: name, title: "\(name) baseline", arguments: arguments)]
        }
        // Mutation testing, when it is a local gate: one run, then its survivors become the accepted baseline.
        if configuration.quality.local.contains("litmus") {
            steps += try locked(
                "litmus",
                title: "litmus (mutation testing)",
                ["run", ".", "--trust-project", "--output", mutationOutput]
            )
            steps.append(
                .tool(
                    name: "litmus",
                    title: "litmus baseline",
                    arguments: [
                        "analyze", ".", "--results", mutationOutput + "/run.pb", "--write-baseline",
                        CIFolder.baseline(of: "litmus")
                    ]
                )
            )
        }
        return steps
    }

    func quality(swiftFiles: [String], fileExists: (String) -> Bool, local: Bool) throws -> [Step] {
        var steps: [Step] = []
        for formatter in project.formatters {
            switch formatter {
                case .swiftFormat:
                    let include = configuration.quality.formatted(for: project).map(Glob.init)
                    let exclude = configuration.quality.exclude.map(Glob.init)
                    let files = swiftFiles.filter { file in
                        include.contains { $0.matches(file) } && !exclude.contains { $0.matches(file) }
                    }
                    guard !files.isEmpty else { continue }
                    let arguments =
                        ["swift", "format", "lint", "--strict", "--parallel", "--configuration", ".swift-format"]
                        + files
                    steps.append(.run(ShellCommand("swift-format (\(files.count) files)", arguments)))
                case .swiftLint:
                    steps += try locked(
                        "swiftlint",
                        title: "SwiftLint",
                        ["lint", "--strict", "--quiet", "--config", ".swiftlint.yml"]
                    )
                case .nickSwiftFormat:
                    steps += try locked("swiftformat", title: "SwiftFormat", ["--lint", "."])
            }
        }
        if let discipline = configuration.quality.discipline { steps.append(.discipline(discipline)) }
        for name in configuration.quality.analyzers {
            let tool = try lock.tool(named: name)
            guard let base = tool.arguments else { throw SwiftCIError("\(name) is a formatter, not an analyzer") }
            var arguments = base
            // `.ci/baselines/<tool>.json`, else the root `.<tool>-baseline.json` the tools write by default.
            if let baseline = [CIFolder.baseline(of: name), ".\(name)-baseline.json"].first(where: fileExists) {
                arguments += ["--baseline", baseline]
            }
            steps.append(.install(tool))
            steps.append(.tool(name: name, title: "\(name) \(tool.version)", arguments: arguments + project.corpus))
        }
        if local {
            for name in configuration.quality.local {
                guard name == "litmus" else {
                    throw SwiftCIError("quality.local: swift-ci knows how to run litmus only, not \(name)")
                }
                // Installed from its pinned release and checked like the analyzers, never taken from PATH.
                steps += try locked(
                    "litmus",
                    title: "litmus (mutation testing)",
                    ["run", ".", "--trust-project", "--output", mutationOutput]
                )
                // A baseline accepts today's survivors (as the analyzers' do): then only a new one fails.
                let baseline = CIFolder.baseline(of: "litmus")
                let gate =
                    fileExists(baseline) ? ["--baseline", baseline, "--gate", "new-survivors"] : ["--strict"]
                steps.append(
                    .tool(
                        name: "litmus",
                        title: "litmus verdict",
                        arguments: ["analyze", ".", "--results", mutationOutput + "/run.pb"] + gate
                    )
                )
            }
        }
        return steps
    }
}
