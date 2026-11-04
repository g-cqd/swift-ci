import Foundation
import SwiftCIKit
import Testing

struct StepsTests {
    func steps(
        _ id: String,
        _ json: String = "{}",
        project: Project = package,
        files: [String] = [],
        existing: Set<String> = [],
        local: Bool = false
    ) throws -> [String] {
        let planner = StepPlanner(
            configuration: try configuration(json),
            project: project,
            lock: .builtIn,
            mutationOutput: "/tmp/mutation-run"
        )
        return commandLines(
            try planner.steps(for: id, swiftFiles: files, fileExists: { existing.contains($0) }, local: local)
        )
    }

    @Test func `a package builds its tests once and runs them without building again`() throws {
        #expect(try steps(CheckID.linuxDebug) == ["swift build --build-tests", "swift test --skip-build"])
        #expect(
            try steps(CheckID.macOSDebug) == [
                "swift build --build-tests --enable-code-coverage", "swift test --skip-build --enable-code-coverage"
            ]
        )
        // Without -enable-testing, `swift test -c release` would rebuild what `swift build -c release` built.
        #expect(
            try steps(CheckID.linuxRelease) == [
                "swift build --build-tests -c release -Xswiftc -enable-testing", "swift test --skip-build -c release"
            ]
        )
        // On Linux, LeakSanitizer is told about the XCTest runner's objects, and nothing else.
        #expect(
            try steps(CheckID.linuxAddress) == [
                "write .build/swift-ci/lsan-suppressions.txt",
                "LSAN_OPTIONS=suppressions=.build/swift-ci/lsan-suppressions.txt swift build --build-tests --sanitize=address",
                "LSAN_OPTIONS=suppressions=.build/swift-ci/lsan-suppressions.txt swift test --skip-build --sanitize=address"
            ]
        )
        #expect(
            leakSuppressions.contains("leak:libXCTest.so\n")
                && leakSuppressions.contains("leak:Foundation7ProcessC3run\n")
                && leakSuppressions.contains("leak:FoundationEssentials17readBytesFromFile\n")
        )
        #expect(
            try steps(CheckID.macOSThread) == [
                "swift build --build-tests --sanitize=thread", "swift test --skip-build --sanitize=thread"
            ]
        )
    }

    @Test func `the environment applies to every build but the consumer's, and serial tests are honoured`() throws {
        let json = #"{"swift": {"environment": {"PKG_DEV": "1"}, "parallel": false}}"#
        #expect(
            try steps(CheckID.linuxDebug, json) == [
                "PKG_DEV=1 swift build --build-tests", "PKG_DEV=1 swift test --skip-build --no-parallel"
            ]
        )
        #expect(
            try steps(CheckID.consumer, json) == ["swift build --build-tests", "swift test --skip-build --no-parallel"]
        )
    }

    @Test func `an Xcode project builds for testing, tests without building, then its local packages`() throws {
        let xcode = Project(
            kind: .xcodeWorkspace,
            xcode: "App.xcworkspace",
            linux: false,
            formatters: [],
            corpus: ["."]
        )
        let json =
            #"{"project": {"schemes": ["App"], "testPlan": "Unit", "destination": "platform=iOS Simulator,name=iPhone 17", "packages": ["Core"]}}"#
        let base =
            "-workspace App.xcworkspace -scheme App -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/swift-ci/DerivedData -testPlan Unit"
        #expect(
            try steps(CheckID.macOSDebug, json, project: xcode) == [
                "xcodebuild build-for-testing \(base) -enableCodeCoverage YES",
                "xcodebuild test-without-building \(base) -enableCodeCoverage YES -resultBundlePath .build/swift-ci/results/App-debug.xcresult",
                "swift build --build-tests --package-path Core --enable-code-coverage",
                "swift test --skip-build --package-path Core --enable-code-coverage"
            ]
        )
        #expect(
            try steps(CheckID.macOSAddress, json, project: xcode)[0]
                == "xcodebuild build-for-testing \(base) -enableAddressSanitizer YES"
        )
    }

    @Test func `platforms build every scheme for each one, and need schemes`() throws {
        let json =
            #"{"project": {"schemes": ["Lib-Package"]}, "platforms": [{"name": "iOS"}, {"name": "watchOS", "destination": "generic/platform=watchOS,arch=arm64_32"}]}"#
        #expect(
            try steps(CheckID.platforms, json) == [
                "xcodebuild build -scheme Lib-Package -destination generic/platform=iOS -derivedDataPath .build/swift-ci/DerivedData",
                "xcodebuild build -scheme Lib-Package -destination generic/platform=watchOS,arch=arm64_32 -derivedDataPath .build/swift-ci/DerivedData"
            ]
        )
        #expect(throws: SwiftCIError.self) { try steps(CheckID.platforms, #"{"platforms": [{"name": "iOS"}]}"#) }
    }

    @Test func `documentation of several targets is one combined archive, warnings fail it`() throws {
        #expect(
            try steps(CheckID.documentation, #"{"documentation": {"targets": ["Core", "Kit"]}}"#) == [
                "swift package --allow-writing-to-directory .build/swift-ci/docs generate-documentation --target Core --target Kit --enable-experimental-combined-documentation --output-path .build/swift-ci/docs --warnings-as-errors"
            ]
        )
    }

    @Test func `archives build each executable in release, then package it`() throws {
        #expect(
            try steps(CheckID.archiveLinux, #"{"release": {"executables": ["tool"]}}"#) == [
                "swift build -c release --product tool -Xlinker -rpath -Xlinker '$ORIGIN'", "archive tool linux"
            ]
        )
        #expect(
            try steps(CheckID.archiveMacOS, #"{"release": {"executables": ["tool"]}}"#) == [
                "swift build -c release --product tool", "archive tool macOS"
            ]
        )
        #expect(throws: SwiftCIError.self) { try steps(CheckID.archiveLinux) }
    }

    @Test func `quality formats the Swift files outside the exclusions, then runs each analyzer with its baseline`()
        throws
    {
        let files = [
            "Package.swift", "Sources/A/a.swift", "Tests/AT/Fixtures/bad.swift", "Sources/Generated/G.swift",
            "Benchmarks/B.swift",
            "development/probe.swift"
        ]
        let lines = try steps(CheckID.quality, files: files, existing: [".dolly-baseline.json"])
        #expect(
            lines.first
                == "swift format lint --strict --parallel --configuration .swift-format Package.swift Sources/A/a.swift"
        )
        #expect(
            Array(lines.dropFirst()) == [
                "install deadwood", "deadwood analyze --strict --no-cache --relative-to . Sources Tests",
                "install dolly",
                "dolly analyze --strict --no-cache --relative-to . --baseline .dolly-baseline.json Sources Tests",
                "install arcleak", "arcleak analyze --strict --no-cache --relative-to . Sources Tests"
            ]
        )
    }

    @Test func `SwiftLint and SwiftFormat come from the lock; modeler checks; litmus runs only locally`() throws {
        let project = Project(
            kind: .package,
            linux: true,
            formatters: [.swiftLint, .nickSwiftFormat],
            corpus: ["Sources"]
        )
        let json = #"{"quality": {"analyzers": ["modeler"], "local": ["litmus"]}}"#
        let lines = try steps(CheckID.quality, json, project: project)
        #expect(
            lines == [
                "install swiftlint", "swiftlint lint --strict --quiet --config .swiftlint.yml", "install swiftformat",
                "swiftformat --lint .", "install modeler", "modeler check --strict --no-cache --relative-to . Sources"
            ]
        )
        let local = try steps(CheckID.quality, json, project: project, local: true)
        #expect(
            local.suffix(3) == [
                "install litmus",
                "litmus run . --trust-project --output /tmp/mutation-run",
                "litmus analyze . --results /tmp/mutation-run/run.pb --strict"
            ]
        )
        // With a baseline, only a new survivor fails; without the opt-in, no mutation testing runs locally.
        let gated = try steps(
            CheckID.quality,
            json,
            project: project,
            existing: [".ci/baselines/litmus.json"],
            local: true
        )
        #expect(
            gated.last
                == "litmus analyze . --results /tmp/mutation-run/run.pb --baseline .ci/baselines/litmus.json --gate new-survivors"
        )
        #expect(
            !(try steps(CheckID.quality, project: project, local: true)).contains { $0.hasPrefix("install litmus") }
        )
        #expect(throws: SwiftCIError.self) { try steps(CheckID.quality, #"{"quality": {"analyzers": ["swiftlint"]}}"#) }
        #expect(throws: SwiftCIError.self) { try steps(CheckID.quality, #"{"quality": {"analyzers": ["unknown"]}}"#) }
    }

    @Test func `a command runs as written, and an unknown id is an error`() throws {
        #expect(
            try steps("oracle", #"{"commands": [{"id": "oracle", "run": "Scripts/oracle.sh --all"}]}"#) == [
                "sh: Scripts/oracle.sh --all"
            ]
        )
        #expect(throws: SwiftCIError.self) { try steps("nothing") }
    }

    @Test func `a command line quotes what a shell would split`() {
        #expect(ShellCommand("", ["a", "b c", "it's", ""]).description == "a 'b c' 'it'\\''s' ''")
    }
}

struct ToolLockTests {
    @Test func `the built-in lock is complete and has every tool for both platforms`() throws {
        try ToolLock.builtIn.validate()
        for name in ["arcleak", "deadwood", "dolly", "fcheck", "modeler", "swiftlint", "swiftformat"] {
            let tool = try ToolLock.builtIn.tool(named: name)
            for platform in ToolLock.Platform.allCases { _ = try tool.archive(for: platform) }
        }
    }

    @Test func `archive URLs and binary paths fill in the version and platform`() throws {
        let dolly = try ToolLock.builtIn.tool(named: "dolly")
        #expect(
            try dolly.archive(for: .linuxX86_64).url
                == "https://github.com/g-cqd/dolly/releases/download/v0.14.3/dolly-0.14.3-linux-x86_64.tar.gz"
        )
        #expect(dolly.binaryPath(for: .macOSArm64) == "dolly-0.14.3-macos-arm64/dolly")
        let swiftformat = try ToolLock.builtIn.tool(named: "swiftformat")
        #expect(swiftformat.binaryPath(for: .linuxX86_64) == "swiftformat_linux")
        #expect(swiftformat.binaryPath(for: .macOSArm64) == "swiftformat")
    }

    @Test func `a lock with a short hash, an http URL or a duplicate is refused`() {
        func lock(_ archive: String, twice: Bool = false) -> Data {
            let tool = #"{"name": "t", "version": "1", "binary": "t", "archives": {"macos-arm64": \#(archive)}}"#
            return Data(#"{"tools": [\#(tool)\#(twice ? ", " + tool : "")]}"#.utf8)
        }
        let good = #"{"url": "https://x/t.tar.gz", "sha256": "\#(String(repeating: "a", count: 64))"}"#
        #expect(throws: Never.self) { try ToolLock.decode(lock(good)) }
        #expect(throws: SwiftCIError.self) { try ToolLock.decode(lock(#"{"url": "https://x", "sha256": "abc"}"#)) }
        #expect(throws: SwiftCIError.self) {
            try ToolLock.decode(lock(#"{"url": "http://x", "sha256": "\#(String(repeating: "a", count: 64))"}"#))
        }
        #expect(throws: SwiftCIError.self) { try ToolLock.decode(lock(good, twice: true)) }
    }
}

struct ShellTests {
    @Test func `a command's output is read, a failure throws a readable summary, and quiet hides standard error`()
        throws
    {
        #expect(try Shell.output(["printf", "%s", "a b"]) == "a b")
        try Shell.run(["true"])
        #expect {
            try Shell.run(["false"])
        } throws: { "\($0)" == "false exited with 1" }
        let many = ["sh", "-c", "exit 3"] + (1 ... 9).map(String.init)
        #expect {
            try Shell.run(many)
        } throws: { "\($0)".contains("… (4 more arguments) exited with 3") }
        #expect(try Shell.output(["sh", "-c", "echo out; echo err >&2"], quiet: true) == "out\n")
    }
}

struct SanitizerSkipTests {
    @Test func `a stack depth exception applies only to its named sanitizer`() throws {
        let config = try configuration(
            #"{"swift":{"sanitizerSkips":{"address":["deeply nested input is refused at the limit"]}}}"#
        )
        let planner = StepPlanner(configuration: config, project: package, lock: .builtIn)
        guard case .run(let test) = try planner.steps(for: CheckID.linuxAddress).last else {
            Issue.record("missing test step")
            return
        }
        #expect(test.arguments.suffix(2) == ["--skip", "deeply nested input is refused at the limit"])
        for id in [CheckID.linuxDebug, CheckID.linuxRelease, CheckID.linuxThread] {
            #expect(!commandLines(try planner.steps(for: id)).joined().contains("--skip "))
        }
    }
}

struct LinuxLeakSuppressionTests {
    @Test func `a reproduced dependency leak can add a symbol without disabling other leak reports`() throws {
        let config = try configuration(#"{"swift":{"linuxLeakSuppressions":["_CFRegularExpressionCreate"]}}"#)
        let planner = StepPlanner(configuration: config, project: package, lock: .builtIn)
        guard case .file(_, let contents) = try planner.steps(for: CheckID.linuxAddress).first else {
            Issue.record("missing suppressions file")
            return
        }
        #expect(contents == leakSuppressions + "leak:_CFRegularExpressionCreate\n")
        #expect(!commandLines(try planner.steps(for: CheckID.macOSAddress)).joined().contains("LSAN_OPTIONS"))
    }

    @Test(arguments: ["*", "", "symbol\nleak:*", "leak:symbol", "symbol/path"])
    func `only symbols are accepted not suppression file syntax`(_ symbol: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["swift": ["linuxLeakSuppressions": [symbol]]])
        #expect(throws: SwiftCIError.self) { try Configuration.decode(data) }
    }
}

struct ActionFailureLogTests {
    @Test func `the macOS action prints a failing command log even under the runner errexit shell`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let action = try String(contentsOf: root.appendingPathComponent("action.yml"), encoding: .utf8)
        let start = try #require(action.range(of: "        set -uo pipefail\n"))
        let script = action[start.lowerBound...].split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.dropFirst(8)) }.joined(separator: "\n")
        let sandbox = try Sandbox()
        let output = sandbox.root.appendingPathComponent("output")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-e", "-o", "pipefail", "-c", "swift-ci() { echo expected-build-diagnostic; return 17; };\n" + script
        ]
        process.currentDirectoryURL = sandbox.root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "RUNNER_OS": "macOS", "RUNNER_TEMP": sandbox.root.path, "COMMAND": "run", "ARGUMENTS": "macos-debug",
            "CONFIG": ".ci/action.json",
            "GIT_CONFIG_GLOBAL": sandbox.root.appendingPathComponent("gitconfig").path
        ]) { $1 }
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 17)
        #expect(try String(contentsOf: output, encoding: .utf8).contains("expected-build-diagnostic"))
    }
}

struct CommandLineHelpTests {
    @Test func `a subcommand help prints the usage and runs nothing`() throws {
        let sandbox = try Sandbox(["Package.swift": "// swift-tools-version: 6.2\n"])
        let cli = try #require(Self.cli)
        for command in ["local", "run", "plan", "baseline"] {
            let process = Process()
            process.executableURL = cli
            process.arguments = [command, "--help", "--root", sandbox.root.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(command) --help")
            #expect(text.contains("swift-ci local [<check>...]"), "\(command) --help printed the usage")
            #expect(!text.contains("==>"), "\(command) --help ran a step")
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent(".build").path))
    }

    /// The CLI in SwiftPM's products directory, beside this target's resource bundle (`swift build --build-tests`
    /// and `swift test` build both).
    static var cli: URL? {
        // The bundle may resolve inside the test bundle (macOS) or beside it (Linux): walk up to the products directory.
        var directory = Bundle.module.bundleURL
        for _ in 0 ..< 6 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent("swift-ci")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                FileManager.default.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }
        return nil
    }
}

struct LocalToolLockTests {
    @Test func `litmus is pinned for local mutation testing on macOS only`() throws {
        let litmus = try ToolLock.builtIn.tool(named: "litmus")
        #expect(litmus.version == "0.3.1")
        #expect(litmus.archives.keys.sorted() == [ToolLock.Platform.macOSArm64.rawValue])
        #expect(litmus.binaryPath(for: .macOSArm64) == "litmus-0.3.1-macos-arm64/litmus")
        #expect(litmus.arguments == nil)
    }
}

struct MutationOutputTests {
    @Test func `each local mutation run writes to a new directory outside the project`() {
        let first = StepPlanner(configuration: Configuration(), project: package, lock: .builtIn, root: "/work/p")
        let second = StepPlanner(configuration: Configuration(), project: package, lock: .builtIn, root: "/work/p")
        #expect(first.mutationOutput != second.mutationOutput)
        #expect(!first.mutationOutput.hasPrefix("/work/p"))
        #expect(!FileManager.default.fileExists(atPath: first.mutationOutput))
    }
}
