import Foundation
import SwiftCIKit

let usage = """
    swift-ci: plan, run and check a Swift package's or Xcode project's CI, the same way in CI and on a developer's machine.

      swift-ci init [--ref REF]                write .ci/action.json and the workflow calling swift-ci at REF
      swift-ci bootstrap                       write .ci/swift-ci, which runs the swift-ci commit CI pins
      swift-ci baseline                        accept the analyzers' current findings (.ci/baselines/<tool>.json)
      swift-ci detect                          what the project is, as swift-ci reads it
      swift-ci validate                        check .ci/action.json and the tool lock
      swift-ci dependabot [--write]            the repository's .github/dependabot.yml, from its manifests and
                                               workflows (the quality check fails when the file differs)
      swift-ci run advisories                  every pinned version of every Package.resolved against the published
                                               advisories (its repository's and GitHub's database)
      swift-ci plan [--event E --ref R --base SHA] [--github-output FILE]
                                               the jobs of an event (JSON; GitHub outputs in Actions). E is a GitHub
                                               event name or a trigger: push, pull-request, merge-queue, nightly, tag,
                                               dispatch. In GitHub Actions all three come from the run.
      swift-ci steps <check>                   the steps of a check, without running them
      swift-ci run <check> [--tag T] [--dry-run]
                                               run a check (or a command of .ci/action.json)
      swift-ci local [<check>...] [--dry-run]  quality (with the local-only tools) and this machine's debug tests
      swift-ci publish --assets DIR --tag T --repository OWNER/NAME [--dry-run]
      swift-ci release-note NOTE ASSETS        lint a release note against the .sha256 files in ASSETS, print it filled
      swift-ci version
      swift-ci family graph                    the family under --root (the umbrella): its repositories by pin level
      swift-ci family clean                    remove what a repin without --push left (worktrees, family-repin branches)
      swift-ci family repin REPO[@REV]... [--all] [--heads] [--push]
                                               repin what a change to REPO forces, level by level, each in a
                                               worktree beside its checkout, gated by its swift-ci quality; REV is
                                               REPO's origin/main by default; --all every member at its origin/main
                                               (the family up to date); --heads takes every member's local
                                               main (the family built at its heads); --push pushes each level
                                               and the umbrella, else the commits stay on family-repin branches

    Options: --root DIR (default: the current directory), --config FILE (default: .ci/action.json).
    """

let version = "0.1.0"

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        var index = 0
        let valued: Set<String> = [
            "--root", "--config", "--event", "--ref", "--base", "--github-output", "--tag", "--assets", "--repository"
        ]
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument) {
                guard index + 1 < arguments.count else { throw SwiftCIError("\(argument) needs a value") }
                options[argument] = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--") {
                guard ["--dry-run", "--help", "--push", "--heads", "--all", "--write"].contains(argument) else {
                    throw SwiftCIError("unknown option \(argument)")
                }
                flags.insert(argument)
                index += 1
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    func require(_ option: String) throws -> String {
        guard let value = options[option], !value.isEmpty else { throw SwiftCIError("\(option) is required") }
        return value
    }
}

func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func compact(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Appends to a file, creating it.
func append(_ text: String, to path: String) throws {
    if !FileManager.default.fileExists(atPath: path) { _ = FileManager.default.createFile(atPath: path, contents: nil) }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

func main() throws {
    var all = Array(CommandLine.arguments.dropFirst())
    guard let command = all.first, command != "--help", command != "help" else { return print(usage) }
    all.removeFirst()
    let arguments = try Arguments(all)
    // Help never runs anything: a subcommand's --help prints the usage and stops.
    if arguments.flags.contains("--help") { return print(usage) }
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let root = URL(fileURLWithPath: arguments.options["--root"] ?? ".", isDirectory: true, relativeTo: current)
        .standardizedFileURL
    let configFile = arguments.options["--config"] ?? CIFolder.configuration
    let dryRun = arguments.flags.contains("--dry-run")

    func context() throws -> (Configuration, Project, ToolLock) {
        let configuration = try Configuration.load(root: root, file: configFile)
        let project = try Project.detect(root: root, configuration: configuration)
        return (configuration, project, try ToolLock.load(root: root, configuration: configuration))
    }
    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    switch command {
        case "version":
            print(version)
        case "family":
            try runFamily(arguments, root: root)
        case "init":
            let configuration = try Configuration.load(root: root, file: configFile)
            let project = try Project.detect(root: root, configuration: configuration, requireSchemes: false)
            var schemes = configuration.project.schemes
            if project.isXcode, schemes.isEmpty, let xcode = project.xcode {
                let flag = project.kind == .xcodeWorkspace ? "-workspace" : "-project"
                let list = try Shell.output(["xcodebuild", "-list", "-json", flag, xcode], directory: root, quiet: true)
                schemes = try Scaffold.schemes(fromXcodebuildList: Data(list.utf8))
            }
            let files = try Scaffold.files(
                project: project,
                schemes: schemes,
                ref: arguments.options["--ref"] ?? "main"
            )
            let (written, kept) = try Scaffold.write(files, root: root)
            for path in written { print("wrote \(path)") }
            for path in kept { print("kept \(path) (it exists)") }
            if project.isXcode { print("\(CIFolder.configuration): keep only the schemes CI should build and test") }
        case "baseline":
            let (configuration, project, lock) = try context()
            let folder = root.appendingPathComponent(CIFolder.path + "/baselines")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var executor = Executor(root: root, dryRun: dryRun)
            try executor.run(
                try StepPlanner(configuration: configuration, project: project, lock: lock, root: root.path).baselines()
            )
            print("wrote \(configuration.quality.analyzers.map(CIFolder.baseline(of:)).joined(separator: ", "))")
        case "detect":
            print(try json(try context().1))
        case "validate":
            let (configuration, project, lock) = try context()
            _ = try Planner(configuration: configuration, project: project)
                .plan(event: Event(trigger: .dispatch, ref: ""), changedFiles: nil)
            try lock.validate()
            try Scaffold.checkBootstrap(root: root)
            print("ok: \(configFile) and the tool lock are valid (\(project.kind.rawValue))")
        case "dependabot":
            let configuration = try Configuration.load(root: root, file: configFile)
            let top = Dependabot.topLevel(of: root)
            guard
                let contents = configuration.dependabot.contents(
                    files: Dependabot.files(top: top),
                    read: Dependabot.reader(top: top)
                )
            else {
                return print("dependabot: no package manifest or workflow to update")
            }
            guard arguments.flags.contains("--write") else { return print(contents, terminator: "") }
            let url = top.appendingPathComponent(Dependabot.path)
            if (try? String(contentsOf: url, encoding: .utf8)) == contents {
                return print("unchanged \(Dependabot.path)")
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            print("wrote \(Dependabot.path)")
        case "bootstrap":
            try Scaffold.writeBootstrap(root: root)
            print("wrote \(Scaffold.bootstrapPath)")
        case "plan":
            let (configuration, project, _) = try context()
            // CI refuses a local bootstrap that would run a different swift-ci than this one.
            try Scaffold.checkBootstrap(root: root)
            // In GitHub Actions the event, the ref and the base come from the run; elsewhere they are given.
            let github = GitHubContext.current
            guard let name = arguments.options["--event"] ?? github.eventName,
                let ref = arguments.options["--ref"] ?? github.ref
            else { throw SwiftCIError("plan needs --event and --ref (outside GitHub Actions)") }
            let event = try Event.named(name, ref: ref)
            let base = arguments.options["--base"] ?? github.base
            let changed =
                [.push, .pullRequest, .mergeQueue].contains(event.trigger)
                ? Git.changedFiles(root: root, base: base) : nil
            let hours = event.trigger == .nightly ? Git.hoursSinceLastCommit(root: root) : nil
            let plan = try Planner(configuration: configuration, project: project)
                .plan(event: event, changedFiles: changed, hoursSinceLastCommit: hours)
            print(try json(plan))
            if let path = arguments.options["--github-output"] ?? ProcessInfo.processInfo.environment["GITHUB_OUTPUT"] {
                let lines = [
                    "linux=\(try compact(plan.linux))", "macos=\(try compact(plan.macOS))",
                    "has-linux=\(!plan.linux.isEmpty)", "has-macos=\(!plan.macOS.isEmpty)",
                    "publish=\(plan.publish)", "skipped=\(plan.skipped ?? "")", "advisories=\(plan.advisories)"
                ]
                try append(lines.joined(separator: "\n") + "\n", to: path)
            }
            if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] {
                var text = "### swift-ci plan (\(plan.trigger.rawValue))\n\n"
                if let skipped = plan.skipped { text += "Nothing to check: \(skipped).\n" }
                for job in plan.linux + plan.macOS { text += "- \(job.title)\n" }
                if plan.publish { text += "- publish the release\n" }
                if plan.advisories { text += "- \(CheckID.title(for: CheckID.advisories))\n" }
                try append(text, to: summary)
            }
        case "steps", "run":
            guard let id = arguments.positional.first else { throw SwiftCIError("\(command) needs a check id") }
            let (configuration, project, lock) = try context()
            let planner = StepPlanner(configuration: configuration, project: project, lock: lock, root: root.path)
            let files = id == CheckID.quality ? try Git.swiftFiles(root: root) : []
            let steps = try planner.steps(for: id, swiftFiles: files, fileExists: fileExists)
            var executor = Executor(
                root: root,
                tag: arguments.options["--tag"] ?? GitHubContext.current.tag,
                dryRun: dryRun || command == "steps"
            )
            try executor.run(steps, keepGoing: id == CheckID.quality)
        case "local":
            let (configuration, project, lock) = try context()
            let planner = StepPlanner(configuration: configuration, project: project, lock: lock, root: root.path)
            _ = try Planner(configuration: configuration, project: project)
                .plan(
                    event: Event(trigger: .dispatch, ref: ""),
                    changedFiles: nil
                )
            let ids = CheckID.local(
                arguments.positional.isEmpty ? configuration.localChecks : arguments.positional,
                commands: configuration.commands
            )
            var executor = Executor(root: root, dryRun: dryRun)
            for id in ids {
                let files = id == CheckID.quality ? try Git.swiftFiles(root: root) : []
                try executor.run(
                    try planner.steps(for: id, swiftFiles: files, fileExists: fileExists, local: true),
                    keepGoing: id == CheckID.quality
                )
            }
        case "publish":
            let configuration = try Configuration.load(root: root, file: configFile)
            let publisher = Publisher(
                root: root,
                assets: URL(fileURLWithPath: try arguments.require("--assets"), relativeTo: current)
                    .standardizedFileURL,
                tag: try arguments.options["--tag"] ?? GitHubContext.current.tag ?? arguments.require("--tag"),
                configuration: configuration,
                dryRun: dryRun
            )
            try publisher.publish(repository: try arguments.require("--repository"))
        case "release-note":
            guard arguments.positional.count == 2 else { throw SwiftCIError("release-note needs NOTE and ASSETS") }
            let configuration = try? Configuration.load(root: root, file: configFile)
            let style = configuration?.release?.noteStyle ?? .structured
            let text = try String(contentsOfFile: arguments.positional[0], encoding: .utf8)
            switch ReleaseNote.fill(
                text,
                assets: try ReleaseNote.assets(in: URL(fileURLWithPath: arguments.positional[1])),
                style: style
            ) {
                case .success(let filled): print(filled, terminator: "")
                case .failure(let problems):
                    for message in problems.messages {
                        FileHandle.standardError.write(
                            Data("release note \(arguments.positional[0]): \(message)\n".utf8)
                        )
                    }
                    exit(1)
            }
        default:
            throw SwiftCIError("unknown command '\(command)'\n\n\(usage)")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("swift-ci: \(error)\n".utf8))
    exit(2)
}

/// `swift-ci family graph` and `swift-ci family repin` (the family's repins, the owner's option A and E, 2026-11-12).
func runFamily(_ arguments: Arguments, root: URL) throws {
    guard let sub = arguments.positional.first else { throw SwiftCIError("family needs graph or repin") }
    switch sub {
        case "graph":
            let family = try Family.load(root: root)
            for (index, level) in family.levels().enumerated() {
                print("level \(index): \(level.map(\.name).joined(separator: ", "))")
            }
        case "repin":
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            where FileManager.default.fileExists(atPath: root.appendingPathComponent(name + "/.git").path) {
                try? Shell.run(["git", "fetch", "-q", "origin"], directory: root.appendingPathComponent(name))
            }
            let family = try Family.load(root: root)
            var bumps: [String: String] = [:]
            // --all: every member at its origin/main; --heads: every member at its local main.
            let every =
                arguments.flags.contains("--heads") ? "main" : arguments.flags.contains("--all") ? "origin/main" : nil
            for member in family.members where every != nil {
                bumps[member.package] =
                    try Shell.output(["git", "rev-parse", every ?? ""], directory: member.path, quiet: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for target in arguments.positional.dropFirst() {
                let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
                guard let member = family.member(parts[0]) else {
                    throw SwiftCIError("no member \(parts[0]) in \(root.path)")
                }
                let revision = try Shell.output(
                    ["git", "rev-parse", parts.count > 1 ? parts[1] : "origin/main"],
                    directory: member.path,
                    quiet: true
                )
                bumps[member.package] = revision.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !bumps.isEmpty else { throw SwiftCIError("family repin needs a REPO, --all or --heads") }
            var repin = FamilyRepin(family: family)
            repin.push = arguments.flags.contains("--push")
            let changes = try repin.run(bumps: bumps)
            for change in changes { print("\(change.member) \(change.revision.prefix(7))") }
            if changes.isEmpty { print("nothing to repin: every pin already names those revisions") }
        case "clean":
            let cleaned = FamilyRepin.clean(try Family.load(root: root))
            print(cleaned.isEmpty ? "nothing to clean" : "cleaned: \(cleaned.joined(separator: ", "))")
        default:
            throw SwiftCIError("family has graph, repin and clean, not \(sub)")
    }
}
