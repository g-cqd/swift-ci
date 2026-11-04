import Foundation
import SwiftCIKit
import Testing

/// `.ci/`: the configuration, and what CI needs beside it, found without being named.
struct CIFolderTests {
    @Test func `the configuration is read from .ci/action.json, and errors name the file`() throws {
        let sandbox = try Sandbox([".ci/action.json": #"{"swift": {"versions": ["6.3.3"]}}"#])
        #expect(try Configuration.load(root: sandbox.root).swift.versions == ["6.3.3"])
        let typo = try Sandbox([".ci/action.json": #"{"swfit": {}}"#, ".ci/other.json": #"{"swfit": {}}"#])
        #expect(throws: (any Error).self) { try Configuration.load(root: typo.root) }
        #expect {
            try Configuration.load(root: typo.root)
        } throws: { "\($0)".hasPrefix(".ci/action.json: unknown key 'swfit'") }
        #expect {
            try Configuration.load(root: typo.root, file: ".ci/other.json")
        } throws: { "\($0)".hasPrefix(".ci/other.json") }
    }

    @Test func `a tool lock in .ci replaces the built-in one, and a broken one names its file`() throws {
        let digest = String(repeating: "a", count: 64)
        let lock =
            #"{"tools": [{"name": "t", "version": "1", "binary": "t", "archives": {"macos-arm64": {"url": "https://x", "sha256": "\#(digest)"}}}]}"#
        let sandbox = try Sandbox([".ci/tools.lock.json": lock])
        #expect(try ToolLock.load(root: sandbox.root, configuration: Configuration()).tools.map(\.name) == ["t"])
        let none = try Sandbox()
        #expect(try ToolLock.load(root: none.root, configuration: Configuration()) == .builtIn)
        let broken = try Sandbox([".ci/tools.lock.json": #"{"tools": [{"name": "t"}]}"#])
        #expect {
            try ToolLock.load(root: broken.root, configuration: Configuration())
        } throws: { "\($0)".hasPrefix(".ci/tools.lock.json") }
        // Named, it must exist.
        #expect(throws: (any Error).self) {
            try ToolLock.load(root: none.root, configuration: try configuration(#"{"quality": {"lock": "x.json"}}"#))
        }
    }

    @Test func `an analyzer's baseline in .ci/baselines wins over the root one`() throws {
        let planner = StepPlanner(
            configuration: try configuration(#"{"quality": {"analyzers": ["dolly"]}}"#),
            project: package,
            lock: .builtIn
        )
        let both: Set<String> = [".ci/baselines/dolly.json", ".dolly-baseline.json"]
        let steps = commandLines(try planner.steps(for: CheckID.quality, fileExists: { both.contains($0) }))
        #expect(
            steps.last
                == "dolly analyze --strict --no-cache --relative-to . --baseline .ci/baselines/dolly.json Sources Tests"
        )
        let root = commandLines(try planner.steps(for: CheckID.quality, fileExists: { $0 == ".dolly-baseline.json" }))
        #expect(
            root.last
                == "dolly analyze --strict --no-cache --relative-to . --baseline .dolly-baseline.json Sources Tests"
        )
    }
}

struct ScaffoldTests {
    @Test func `a package gets an empty configuration and a workflow pinned to the commit`() throws {
        let commit = String(repeating: "c", count: 40)
        let files = try Scaffold.files(project: package, schemes: [], ref: commit)
        #expect(files.map(\.path) == [".ci/action.json", ".github/workflows/ci.yml", ".ci/swift-ci"])
        #expect(files[0].contents == "{}\n")
        #expect(try Configuration.decode(Data(files[0].contents.utf8)) == Configuration())
        #expect(files[1].contents.contains("uses: g-cqd/swift-ci/.github/workflows/swift-ci.yml@\(commit)\n"))
        #expect(
            try Scaffold.files(project: package, schemes: [], ref: "main")[1].contents.contains("@main  # pin a commit")
        )
    }

    @Test func `an Xcode project gets its schemes and the selected Xcode's toolchain`() throws {
        let xcode = Project(
            kind: .xcodeWorkspace,
            xcode: "App.xcworkspace",
            linux: false,
            formatters: [],
            corpus: ["."]
        )
        let files = try Scaffold.files(project: xcode, schemes: ["App", "AppTests"], ref: "main")
        let decoded = try Configuration.decode(Data(files[0].contents.utf8))
        #expect(decoded.project.schemes == ["App", "AppTests"])
        #expect(decoded.project.xcode == "App.xcworkspace")
        #expect(decoded.swift.macOSVersion == nil)
    }

    @Test func `nothing that exists is overwritten`() throws {
        let sandbox = try Sandbox([".github/workflows/ci.yml": "mine"])
        let (written, kept) = try Scaffold.write(
            try Scaffold.files(project: package, schemes: [], ref: "main"),
            root: sandbox.root
        )
        #expect(written == [".ci/action.json", ".ci/swift-ci"] && kept == [".github/workflows/ci.yml"])
        #expect(FileManager.default.isExecutableFile(atPath: sandbox.root.appendingPathComponent(".ci/swift-ci").path))
        #expect(
            try String(contentsOf: sandbox.root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
                == "mine"
        )
    }

    @Test func `schemes come from xcodebuild -list for a project or a workspace`() throws {
        #expect(
            try Scaffold.schemes(fromXcodebuildList: Data(#"{"workspace": {"name": "W", "schemes": ["A", "B"]}}"#.utf8))
                == ["A", "B"]
        )
        #expect(
            try Scaffold.schemes(fromXcodebuildList: Data(#"{"project": {"schemes": ["P"], "targets": []}}"#.utf8)) == [
                "P"
            ]
        )
        #expect(try Scaffold.schemes(fromXcodebuildList: Data("{}".utf8)) == [])
    }
}

struct AdoptionTests {
    @Test func `swift-format checks only what quality.include names, minus quality.exclude`() throws {
        let json = #"{"quality": {"include": ["Package.swift", "Sources/**", "Tests/*/*.swift"], "analyzers": []}}"#
        let planner = StepPlanner(configuration: try configuration(json), project: package, lock: .builtIn)
        let files = [
            "Package.swift", "Sources/A/a.swift", "Tests/AT/t.swift", "Tests/AT/Fixtures/f.swift", "Benchmarks/b.swift"
        ]
        #expect(
            commandLines(try planner.steps(for: CheckID.quality, swiftFiles: files)) == [
                "swift format lint --strict --parallel --configuration .swift-format Package.swift Sources/A/a.swift Tests/AT/t.swift"
            ]
        )
    }

    @Test func `baseline writes each analyzer's findings into .ci/baselines`() throws {
        let planner = StepPlanner(
            configuration: try configuration(#"{"quality": {"analyzers": ["dolly", "modeler"]}}"#),
            project: package,
            lock: .builtIn
        )
        #expect(
            commandLines(try planner.baselines()) == [
                "install dolly",
                "dolly analyze --strict --no-cache --relative-to . --write-baseline .ci/baselines/dolly.json Sources Tests",
                "install modeler",
                "modeler check --strict --no-cache --relative-to . --write-baseline .ci/baselines/modeler.json Sources Tests"
            ]
        )
        let mutation = StepPlanner(
            configuration: try configuration(#"{"quality": {"analyzers": [], "local": ["litmus"]}}"#),
            project: package,
            lock: .builtIn,
            mutationOutput: "/tmp/m"
        )
        #expect(
            commandLines(try mutation.baselines()) == [
                "install litmus", "litmus run . --trust-project --output /tmp/m",
                "litmus analyze . --results /tmp/m/run.pb --write-baseline .ci/baselines/litmus.json"
            ]
        )
    }

    @Test func `a command can leave release archives, and the archive checks always do`() throws {
        let json =
            #"{"release": {"executables": ["t"]}, "commands": [{"id": "full", "run": "x", "os": "macOS", "cadence": ["tag"], "archives": true}, {"id": "plain", "run": "y", "cadence": ["tag"]}]}"#
        let plan = try Planner(configuration: try configuration(json), project: package)
            .plan(event: Event(trigger: .tag, ref: "refs/tags/v1"), changedFiles: nil)
        let archives = (plan.linux + plan.macOS).filter(\.archives).map(\.id).sorted()
        #expect(archives == [CheckID.archiveLinux, CheckID.archiveMacOS, "full"])
    }

    @Test func `keep going runs every step and reports the failures together`() throws {
        let sandbox = try Sandbox()
        var executor = Executor(root: sandbox.root)
        let steps: [Step] = [
            .run(ShellCommand("first", ["false"])), .file(path: "reached", contents: ""),
            .run(ShellCommand("third", ["false"]))
        ]
        #expect {
            try executor.run(steps, keepGoing: true)
        } throws: { "\($0)" == "2 step(s) failed: first, third" }
        #expect(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("reached").path))
        let stopped = try Sandbox()
        var strict = Executor(root: stopped.root)
        #expect(throws: SwiftCIError.self) { try strict.run(steps) }
        #expect(!FileManager.default.fileExists(atPath: stopped.root.appendingPathComponent("reached").path))
    }
}

struct AfterTests {
    let json = #"""
        {"release": {"executables": ["t"]},
         "commands": [
           {"id": "self-analysis", "run": "swift run t analyze Sources", "after": "linux-debug"},
           {"id": "no-gcd", "run": "Scripts/no-gcd.sh", "after": "quality"},
           {"id": "full", "run": "Scripts/full.sh", "after": "archive-macos", "archives": true},
           {"id": "alone", "run": "x"}
         ]}
        """#

    @Test func `a command after a check runs at the end of that check's job, not in a job of its own`() throws {
        let planner = StepPlanner(configuration: try configuration(json), project: package, lock: .builtIn)
        #expect(commandLines(try planner.steps(for: CheckID.linuxDebug)).last == "sh: swift run t analyze Sources")
        #expect(commandLines(try planner.steps(for: CheckID.quality)).last == "sh: Scripts/no-gcd.sh")
        let plan = try Planner(configuration: try configuration(json), project: package)
            .plan(event: Event(trigger: .tag, ref: "refs/tags/v1"), changedFiles: nil)
        let ids = (plan.linux + plan.macOS).map(\.id)
        #expect(
            ids.contains("alone") && !ids.contains("self-analysis") && !ids.contains("no-gcd") && !ids.contains("full")
        )
        // The host of a command that leaves archives uploads them.
        #expect(plan.macOS.first { $0.id == CheckID.archiveMacOS }?.archives == true)
    }

    @Test func `after must name a check or a command that runs on its own`() {
        #expect(throws: SwiftCIError.self) {
            try Planner(
                configuration: try configuration(#"{"commands": [{"id": "a", "run": "x", "after": "nothing"}]}"#),
                project: package
            )
            .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
        }
        #expect(throws: SwiftCIError.self) {
            let chained =
                #"{"commands": [{"id": "a", "run": "x", "after": "quality"}, {"id": "b", "run": "y", "after": "a"}]}"#
            _ = try Planner(configuration: try configuration(chained), project: package)
                .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
        }
    }
}

struct BeforeTests {
    @Test func `fixture preparation runs before each selected check without creating a job`() throws {
        let config = try configuration(
            #"""
            {"commands": [
              {"id": "fixtures", "run": "fetch-fixtures", "before": ["linux-debug", "consumer", "macos-debug"]},
              {"id": "verify", "run": "verify-fixtures", "before": ["linux-debug"]}
            ]}
            """#
        )
        let steps = StepPlanner(configuration: config, project: package, lock: .builtIn)
        for id in [CheckID.linuxDebug, CheckID.consumer, CheckID.macOSDebug] {
            #expect(commandLines(try steps.steps(for: id)).first == "sh: fetch-fixtures")
        }
        #expect(commandLines(try steps.steps(for: CheckID.linuxDebug))[1] == "sh: verify-fixtures")
        #expect(commandLines(try steps.steps(for: CheckID.linuxRelease)).first != "sh: fetch-fixtures")
        let plan = try Planner(configuration: config, project: package)
            .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
        #expect(!(plan.linux + plan.macOS).contains { ["fixtures", "verify"].contains($0.id) })
    }

    @Test(arguments: [
        #"[{"id":"a","run":"x","before":["missing"]}]"#,
        #"[{"id":"a","run":"x","before":["a"]}]"#,
        #"[{"id":"a","run":"x","before":["quality"],"after":"linux-debug"}]"#,
        #"[{"id":"a","run":"x","before":["quality"]},{"id":"b","run":"x","after":"a"}]"#,
        #"[{"id":"a","run":"x","after":"quality"},{"id":"b","run":"x","before":["a"]}]"#
    ])
    func `preparation rejects unknown hosts self references mixed directions and hook chains`(_ commands: String) {
        #expect(throws: SwiftCIError.self) {
            _ = try Planner(configuration: configuration("{\"commands\":\(commands)}"), project: package)
                .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
        }
    }
}

struct BootstrapTests {
    @Test func `the bootstrap is valid bash and runs the commit the workflow pins`() throws {
        let sandbox = try Sandbox(["bootstrap": Scaffold.bootstrap])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", sandbox.root.appendingPathComponent("bootstrap").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(Scaffold.bootstrap.contains("g-cqd/swift-ci/\\.github/workflows/swift-ci\\.yml@[0-9a-f]{40}"))
        #expect(Scaffold.bootstrap.hasSuffix("exec \"$cli\" \"$@\" --root \"$root\"\n"))
    }

    /// `.ci/bootstrap.sh` is the bootstrap as a file, so shellcheck lints the exact text repositories receive.
    @Test func `the embedded bootstrap is byte for byte the linted script`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent(".ci/bootstrap.sh"), encoding: .utf8)
        #expect(file == Scaffold.bootstrap)
    }

    @Test func `an edited, outdated or non-executable bootstrap is refused; a written one is accepted`() throws {
        let sandbox = try Sandbox()
        try Scaffold.checkBootstrap(root: sandbox.root)  // none: nothing to check
        try Scaffold.writeBootstrap(root: sandbox.root)
        try Scaffold.checkBootstrap(root: sandbox.root)
        let url = sandbox.root.appendingPathComponent(Scaffold.bootstrapPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: SwiftCIError.self) { try Scaffold.checkBootstrap(root: sandbox.root) }
        try (Scaffold.bootstrap + "# edited\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        #expect(throws: SwiftCIError.self) { try Scaffold.checkBootstrap(root: sandbox.root) }
    }
}

struct LocalChecksTests {
    @Test func `local checks default to quality and this machine's debug tests, and are configurable`() throws {
        #if os(macOS)
            let host = CheckID.macOSDebug
        #else
            let host = CheckID.linuxDebug
        #endif
        #expect(CheckID.local(Configuration().localChecks) == [CheckID.quality, host])
        let json =
            #"{"localChecks": ["quality", "debug", "self-analysis"], "commands": [{"id": "self-analysis", "run": "x", "after": "linux-debug"}]}"#
        let config = try configuration(json)
        // A command attached to a listed check runs with it, not twice.
        let expected = host == CheckID.linuxDebug ? [CheckID.quality, host] : [CheckID.quality, host, "self-analysis"]
        #expect(CheckID.local(config.localChecks, commands: config.commands) == expected)
        #expect(CheckID.local(["linux-debug", "self-analysis"], commands: config.commands) == ["linux-debug"])
        _ = try Planner(configuration: config, project: package)
            .plan(event: Event(trigger: .dispatch, ref: ""), changedFiles: nil)
    }

    @Test func `an unknown local check is refused`() {
        #expect(throws: SwiftCIError.self) {
            _ = try Planner(configuration: configuration(#"{"localChecks": ["quality", "nothing"]}"#), project: package)
                .plan(event: Event(trigger: .dispatch, ref: ""), changedFiles: nil)
        }
    }
}

struct PackageInDirectoryTests {
    /// A repository with a package in a directory: its changed files are its own, relative to it.
    @Test func `changed files from a package in a directory are its own, relative to it`() throws {
        let sandbox = try Sandbox(["Packages/Core/Sources/a.swift": "a\n", "Apps/App/b.swift": "b\n"])
        func git(_ arguments: String...) throws {
            _ = try Shell.output(["git"] + arguments, directory: sandbox.root, quiet: true)
        }
        try git("init", "-q")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "add", "-A")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
        let base = try Shell.output(["git", "rev-parse", "HEAD"], directory: sandbox.root, quiet: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try "a2\n"
            .write(
                to: sandbox.root.appendingPathComponent("Packages/Core/Sources/a.swift"),
                atomically: true,
                encoding: .utf8
            )
        try "b2\n".write(to: sandbox.root.appendingPathComponent("Apps/App/b.swift"), atomically: true, encoding: .utf8)
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "change")
        let core = sandbox.root.appendingPathComponent("Packages/Core")
        #expect(Git.changedFiles(root: core, base: base) == ["Sources/a.swift"])
        #expect(
            Git.changedFiles(root: sandbox.root, base: base)?.sorted() == [
                "Apps/App/b.swift", "Packages/Core/Sources/a.swift"
            ]
        )
    }

    @Test func `the bootstrap reads the pin from the repository's workflows, also from a package in a directory`() {
        #expect(Scaffold.bootstrap.contains(#"top="$(git -C "$root" rev-parse --show-toplevel"#))
        #expect(Scaffold.bootstrap.contains(#""$top"/.github/workflows/*.yml"#))
    }
}
