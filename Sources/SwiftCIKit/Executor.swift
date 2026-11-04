public import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Runs steps from the project root, in order; the first failure stops the job. Inside GitHub Actions each step is a
/// collapsible group.
public struct Executor {
    public var root: URL
    /// The tag of a tag run, checked against an archived executable's `--version`.
    public var tag: String?
    /// Print the steps instead of running them.
    public var dryRun = false
    /// Where locked tools are installed: outside the repository, so every checkout of the machine shares them.
    public var toolCache: URL
    private var installed: [String: URL] = [:]

    public init(root: URL, tag: String? = nil, dryRun: Bool = false, toolCache: URL? = nil) {
        self.root = root
        self.tag = tag
        self.dryRun = dryRun
        self.toolCache = toolCache ?? Self.defaultToolCache()
    }

    static func defaultToolCache() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SWIFT_CI_TOOLS"] { return URL(fileURLWithPath: path) }
        #if os(macOS)
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        #else
            let base =
                environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        #endif
        return base.appendingPathComponent("swift-ci/tools")
    }

    var inActions: Bool { ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" }

    /// Runs `steps`; the first failure stops them, unless `keepGoing`: then every step runs and the failures are
    /// reported together at the end (quality, so one run shows every tool's findings).
    public mutating func run(_ steps: [Step], keepGoing: Bool = false) throws {
        var failures: [String] = []
        for step in steps {
            if inActions { print("::group::\(step.title)") } else { print("==> \(step.title)") }
            fflush(nil)  // before the child writes, so the title stays above its output
            defer {
                if inActions { print("::endgroup::") }
                fflush(nil)
            }
            do {
                try execute(step)
            } catch {
                guard keepGoing else { throw error }
                print("\(inActions ? "::error::" : "[FAIL] ")\(step.title): \(error)")
                failures.append(step.title)
            }
        }
        if !failures.isEmpty {
            throw SwiftCIError("\(failures.count) step(s) failed: \(failures.joined(separator: ", "))")
        }
    }

    mutating func execute(_ step: Step) throws {
        switch step {
            case .run(let command):
                if dryRun { return print(command) }
                if let package = BuildLink.packageDirectory(of: command.arguments),
                    let note = try BuildLink.repair(packageDirectory: root.appendingPathComponent(package))
                {
                    print(note)
                    fflush(nil)
                }
                try Shell.run(command.arguments, environment: command.environment, directory: root)
            case .shell(_, let script):
                if dryRun { return print(script) }
                try Shell.run(["bash", "-euo", "pipefail", "-c", script], directory: root)
            case .install(let tool):
                if dryRun { return print("install \(tool.name) \(tool.version)") }
                installed[tool.name] = try install(tool)
            case .tool(let name, _, let arguments):
                if dryRun { return print(([name] + arguments).map(ShellCommand.quote).joined(separator: " ")) }
                guard let binary = installed[name] else { throw SwiftCIError("\(name) runs before it is installed") }
                try Shell.run([binary.path] + arguments, directory: root)
            case .file(let path, let contents):
                if dryRun { return print("write \(path)") }
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: url, atomically: true, encoding: .utf8)
            case .swiftFormat(let files):
                try lint(files, dryRun: dryRun)
            case .tla(_, let models):
                if dryRun { return print("tlc \(models.models)/*.cfg (tla2tools \(TLC.version))") }
                try check(models)
            case .discipline(let discipline):
                if dryRun { return print("discipline: \(discipline.shipped.joined(separator: " "))") }
                try check(discipline)
            case .archive(let executable, let os):
                if dryRun { return print("archive \(executable) into \(Paths.distribution)") }
                try archive(executable, os: os)
        }
    }

    // MARK: swift-format

    /// swift-format lint over `files`; without NaturalLanguage, with the project's configuration minus the rules that
    /// need it (written outside the project, removed after).
    func lint(_ files: [String], dryRun: Bool) throws {
        let base = root.appendingPathComponent(".swift-format")
        let portable =
            try FileManager.default.fileExists(atPath: base.path)
            ? SwiftFormatLint.portableConfiguration(
                from: try Data(contentsOf: base),
                naturalLanguage: SwiftFormatLint.hasNaturalLanguage
            ) : nil
        guard let portable else {
            let arguments = SwiftFormatLint.arguments(configuration: ".swift-format", files: files)
            if dryRun { return print(ShellCommand("swift-format", arguments)) }
            return try Shell.run(arguments, directory: root)
        }
        let configuration = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ci-format-\(UUID().uuidString).swift-format")
        let arguments = SwiftFormatLint.arguments(configuration: configuration.path, files: files)
        if dryRun { return print(ShellCommand("swift-format", arguments)) }
        print(
            "swift-format: \(SwiftFormatLint.naturalLanguageRules.joined(separator: ", ")) is checked where swift-format"
                + " has NaturalLanguage (macOS), not here"
        )
        try portable.write(to: configuration)
        defer { try? FileManager.default.removeItem(at: configuration) }
        try Shell.run(arguments, directory: root)
    }

    // MARK: Discipline

    /// The textual rules, then swift-format's force-unwrap rules over the shipped targets; every finding is reported
    /// before the step fails.
    func check(_ discipline: Discipline) throws {
        let findings = discipline.scan(root: root)
        for finding in findings { print(finding) }
        var unwraps = 0
        let shipped = discipline.shipped.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        if discipline.forceUnwrap, !shipped.isEmpty {
            let base = root.appendingPathComponent(".swift-format")
            guard FileManager.default.fileExists(atPath: base.path) else {
                throw SwiftCIError("discipline.forceUnwrap needs the project's .swift-format")
            }
            // Outside the project: the check writes nothing into the tree it checks.
            let strict = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-ci-strict-\(UUID().uuidString).swift-format")
            defer { try? FileManager.default.removeItem(at: strict) }
            try Discipline.strictConfiguration(from: try Data(contentsOf: base)).write(to: strict)
            // swift-format lints whitespace with every configuration, and the project's rules are quality's swift-format
            // step: only the force-unwrap rules' findings count here, so a formatting problem is reported once, there.
            let lint = try Shell.combinedOutput(
                ["swift", "format", "lint", "--strict", "--configuration", strict.path, "--recursive"] + shipped,
                directory: root
            )
            switch Discipline.forceUnwrapVerdict(status: lint.status, output: lint.output) {
                case .clean:
                    break
                case .findings(let lines):
                    for line in lines { print(line) }
                    unwraps = lines.count
                case .failed(let reason):
                    print(lint.output, terminator: "")
                    throw SwiftCIError("discipline: swift format lint failed before checking force unwraps: \(reason)")
            }
        }
        if !findings.isEmpty || unwraps > 0 {
            throw SwiftCIError(
                "discipline: \(findings.count) textual finding(s), \(unwraps) force unwrap(s) or try! in shipped code"
            )
        }
        print("discipline: clean (\(shipped.joined(separator: ", ")))")
    }

    // MARK: TLA+

    /// Every model of the directory, each in a state directory of its own; every verdict is printed before the step
    /// fails.
    func check(_ tla: TLAModels) throws {
        let directory = root.appendingPathComponent(tla.models)
        let models = TLC.models((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        guard !models.isEmpty else { throw SwiftCIError("tla: no .cfg model in \(tla.models)") }
        let java = try Self.java()
        let jar = try installTLC()
        let states = FileManager.default.temporaryDirectory.appendingPathComponent("swift-ci-tlc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: states) }
        var failed: [String] = []
        for model in models {
            let run = try Shell.combinedOutput(
                TLC.arguments(
                    java: java,
                    jar: jar.path,
                    model: model,
                    states: states.appendingPathComponent(model.name).path
                ),
                directory: directory
            )
            switch TLC.verdict(mustFail: model.mustFail, status: run.status, output: run.output) {
                case .held(let states): print("[OK] \(model.name): \(states)")
                case .refutedAsItMust(let error): print("[OK] \(model.name) is refuted, as it must be: \(error)")
                case .failed(let reason):
                    print("[FAIL] \(model.name): \(reason)")
                    print(
                        run.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(30)
                            .joined(separator: "\n")
                    )
                    failed.append(model.name)
            }
            fflush(nil)
        }
        guard failed.isEmpty else {
            throw SwiftCIError(
                "tla: \(failed.count) of \(models.count) model(s) failed: \(failed.joined(separator: ", "))"
            )
        }
    }

    /// `$JAVA_HOME/bin/java`, else `java` on the path, checked to run (macOS has a `java` that only asks for a JDK).
    static func java() throws -> String {
        let home = ProcessInfo.processInfo.environment["JAVA_HOME"].map { "\($0)/bin/java" }
        let java = home.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "java"
        guard (try? Shell.combinedOutput([java, "-version"]))?.status == 0 else {
            throw SwiftCIError("tla: TLC needs Java 11 or later (JAVA_HOME, or java on the path)")
        }
        return java
    }

    /// The pinned `tla2tools.jar` in the tool cache, downloaded and checked once.
    func installTLC() throws -> URL {
        let jar = toolCache.appendingPathComponent("tla2tools-\(TLC.version).jar")
        if FileManager.default.fileExists(atPath: jar.path), try Shell.sha256(of: jar) == TLC.sha256 { return jar }
        try FileManager.default.createDirectory(at: toolCache, withIntermediateDirectories: true)
        let part = toolCache.appendingPathComponent("tla2tools-\(TLC.version)-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: part) }
        print("swift-ci: downloading tla2tools \(TLC.version)")
        try Download.fetch(TLC.url, to: part)
        let actual = try Shell.sha256(of: part)
        guard actual == TLC.sha256 else {
            throw SwiftCIError("tla2tools.jar: the SHA-256 is \(actual), not the pinned \(TLC.sha256)")
        }
        try? FileManager.default.removeItem(at: jar)
        try FileManager.default.moveItem(at: part, to: jar)
        return jar
    }

    // MARK: Tools

    /// Installs `tool` unless it is: downloads its archive, checks the pinned SHA-256, unpacks it and checks the
    /// binary reports the pinned version. Returns the binary.
    func install(_ tool: ToolLock.Tool) throws -> URL {
        guard let platform = ToolLock.Platform.current else {
            throw SwiftCIError("no \(tool.name) archive for this machine")
        }
        let directory = toolCache.appendingPathComponent("\(tool.name)-\(tool.version)-\(platform.rawValue)")
        let binary = directory.appendingPathComponent(tool.binaryPath(for: platform))
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }

        let (url, sha256) = try tool.archive(for: platform)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("swift-ci-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent(URL(string: url)?.lastPathComponent ?? "archive")
        try Download.fetch(url, to: archive)
        let actual = try Shell.sha256(of: archive)
        guard actual == sha256 else {
            throw SwiftCIError("\(tool.name): the archive's SHA-256 is \(actual), not the pinned \(sha256)")
        }

        let unpacked = scratch.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        if url.hasSuffix(".zip") {
            try Shell.run(["unzip", "-q", archive.path, "-d", unpacked.path])
        } else {
            try Shell.run(["tar", "-xzf", archive.path, "-C", unpacked.path])
        }
        let reported = try Shell.output([
            unpacked.appendingPathComponent(tool.binaryPath(for: platform)).path, "--version"
        ])
        guard reported.contains(tool.version) else {
            throw SwiftCIError(
                "\(tool.name) reports '\(reported.trimmingCharacters(in: .whitespacesAndNewlines))', not \(tool.version)"
            )
        }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: unpacked, to: directory)
        return binary
    }

    // MARK: Archives

    /// `<executable>-<version>-<os>-<arch>.tar.gz` and its `.sha256` in `.build/swift-ci/dist`: the stripped binary,
    /// LICENSE and README, and on Linux the Swift runtime libraries it links.
    func archive(_ executable: String, os: OS) throws {
        let binDirectory = try Shell.output(["swift", "build", "-c", "release", "--show-bin-path"], directory: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let binary = URL(fileURLWithPath: binDirectory).appendingPathComponent(executable)
        let version = try Shell.output([binary.path, "--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag, version != (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag) {
            throw SwiftCIError("the tag \(tag) is not \(executable)'s --version \(version)")
        }
        let arch = try Shell.output(["uname", "-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = "\(executable)-\(version)-\(os == .macOS ? "macos" : "linux")-\(arch)"
        let dist = root.appendingPathComponent(Paths.distribution)
        let folder = dist.appendingPathComponent(name)
        let files = FileManager.default
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.copyItem(at: binary, to: folder.appendingPathComponent(executable))
        for extra in ["LICENSE", "README.md"] where files.fileExists(atPath: root.appendingPathComponent(extra).path) {
            try files.copyItem(at: root.appendingPathComponent(extra), to: folder.appendingPathComponent(extra))
        }
        let copy = folder.appendingPathComponent(executable).path
        if os == .macOS {
            try Shell.run(["strip", "-S", "-x", copy])
        } else {
            try Shell.run(["strip", copy])
            // Dynamically linked: the Swift runtime libraries go beside the binary.
            for line in try Shell.output(["ldd", binary.path]).split(separator: "\n") {
                let words = line.split(separator: " ")
                if words.count >= 3, words[2].hasPrefix("/usr/lib/swift/") {
                    let library = URL(fileURLWithPath: String(words[2]))
                    let destination = folder.appendingPathComponent(library.lastPathComponent)
                    if !files.fileExists(atPath: destination.path) {
                        try files.copyItem(at: library, to: destination)
                    }
                }
            }
        }
        try Shell.run(["tar", "-czf", "\(name).tar.gz", name], directory: dist)
        let digest = try Shell.sha256(of: dist.appendingPathComponent("\(name).tar.gz"))
        try "\(digest)  \(name).tar.gz\n"
            .write(to: dist.appendingPathComponent("\(name).tar.gz.sha256"), atomically: true, encoding: .utf8)
        print("\(name).tar.gz \(digest)")
    }
}

/// Child processes. Output goes to this process's, so a job's log reads as the commands wrote it.
public enum Shell {
    public static func run(_ arguments: [String], environment: [String: String] = [:], directory: URL? = nil) throws {
        let process = try make(arguments, environment: environment, directory: directory)
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SwiftCIError("\(summary(arguments)) exited with \(process.terminationStatus)")
        }
    }

    /// A command line short enough to read: the first words, then how many more.
    static func summary(_ arguments: [String]) -> String {
        let shown = arguments.prefix(8).map(ShellCommand.quote).joined(separator: " ")
        return arguments.count > 8 ? "\(shown) … (\(arguments.count - 8) more arguments)" : shown
    }

    /// The standard output of a command that must succeed; its standard error is shown only when `quiet` is false.
    public static func output(_ arguments: [String], directory: URL? = nil, quiet: Bool = false) throws -> String {
        let process = try make(arguments, environment: [:], directory: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        if quiet { process.standardError = FileHandle.nullDevice }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SwiftCIError("\(summary(arguments)) exited with \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The exit status and the standard output and error, interleaved as written, of a command that may fail.
    public static func combinedOutput(_ arguments: [String], directory: URL? = nil) throws -> (
        status: Int32, output: String
    ) {
        let process = try make(arguments, environment: [:], directory: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// The SHA-256 of a file, from the system's tool: swift-ci implements no digest.
    public static func sha256(of file: URL) throws -> String {
        #if os(macOS)
            let words = try output(["shasum", "-a", "256", file.path]).split(separator: " ")
        #else
            let words = try output(["sha256sum", file.path]).split(separator: " ")
        #endif
        guard let digest = words.first, digest.count == 64 else { throw SwiftCIError("no SHA-256 of \(file.path)") }
        return digest.lowercased()
    }

    static func make(_ arguments: [String], environment: [String: String], directory: URL?) throws -> Process {
        guard !arguments.isEmpty else { throw SwiftCIError("an empty command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        if let directory { process.currentDirectoryURL = directory }
        return process
    }
}

/// HTTPS downloads with Foundation (no `curl` on the Swift Linux images), retried; a `file:` URL is copied.
enum Download {
    static func fetch(_ address: String, to destination: URL, attempts: Int = 3) throws {
        guard let url = URL(string: address) else { throw SwiftCIError("not a URL: \(address)") }
        if url.isFileURL { return try FileManager.default.copyItem(at: url, to: destination) }
        var failure = "no attempt"
        for attempt in 1 ... attempts {
            switch get(url) {
                case .success(let data):
                    return try data.write(to: destination)
                case .failure(let error):
                    failure = error.description
                    if attempt < attempts { Thread.sleep(forTimeInterval: Double(attempt * 2)) }
            }
        }
        throw SwiftCIError("download of \(address) failed: \(failure)")
    }

    private final class Box: @unchecked Sendable {
        var result: Result<Data, SwiftCIError> = .failure(SwiftCIError("no response"))
    }

    private static func get(_ url: URL) -> Result<Data, SwiftCIError> {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            defer { done.signal() }
            if let error {
                box.result = .failure(SwiftCIError(error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else {
                box.result = .failure(SwiftCIError("HTTP \(status)"))
                return
            }
            box.result = .success(data)
        }
        task.resume()
        done.wait()
        return box.result
    }
}

/// What the plan needs from git.
public enum Git {
    /// The files changed between `base` and HEAD, fetching `base` when the clone is shallow; nil when unknown (a new
    /// branch, a base that cannot be fetched).
    public static func changedFiles(root: URL, base: String?) -> [String]? {
        guard let base, !base.isEmpty, !base.allSatisfy({ $0 == "0" }) else { return nil }
        if (try? Shell.output(["git", "cat-file", "-e", base + "^{commit}"], directory: root, quiet: true)) == nil {
            _ = try? Shell.output(
                ["git", "fetch", "--no-tags", "--depth=1", "origin", base],
                directory: root,
                quiet: true
            )
        }
        guard
            let output = try? Shell.output(
                // --relative: from a package in a directory, only its own files, relative to it.
                ["git", "diff", "--name-only", "--no-renames", "--relative", base, "HEAD"],
                directory: root,
                quiet: true
            )
        else {
            return nil
        }
        return output.split(separator: "\n").map(String.init)
    }

    /// Hours since HEAD was committed.
    public static func hoursSinceLastCommit(root: URL, now: Date = Date()) -> Double? {
        guard let output = try? Shell.output(["git", "log", "-1", "--format=%ct"], directory: root, quiet: true),
            let seconds = Double(output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return (now.timeIntervalSince1970 - seconds) / 3600
    }

    /// Every tracked Swift file.
    public static func swiftFiles(root: URL) throws -> [String] {
        try Shell.output(["git", "ls-files", "--", "*.swift"], directory: root, quiet: true).split(separator: "\n")
            .map(String.init)
    }
}
