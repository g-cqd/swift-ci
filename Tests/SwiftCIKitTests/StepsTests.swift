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
        let planner = StepPlanner(configuration: try configuration(json), project: project, lock: .builtIn)
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
                "swift build -c release --product tool", "archive tool linux"
            ]
        )
        #expect(throws: SwiftCIError.self) { try steps(CheckID.archiveLinux) }
    }

    @Test func `quality formats the Swift files outside the exclusions, then runs each analyzer with its baseline`()
        throws
    {
        let files = ["Package.swift", "Sources/A/a.swift", "Tests/AT/Fixtures/bad.swift", "Sources/Generated/G.swift"]
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
        let json = #"{"quality": {"analyzers": ["modeler"]}}"#
        let lines = try steps(CheckID.quality, json, project: project)
        #expect(
            lines == [
                "install swiftlint", "swiftlint lint --strict --quiet --config .swiftlint.yml", "install swiftformat",
                "swiftformat --lint .", "install modeler", "modeler check --strict --no-cache --relative-to . Sources"
            ]
        )
        let local = try steps(CheckID.quality, json, project: project, local: true)
        #expect(
            local.suffix(2) == [
                "litmus run . --trust-project --output .build/swift-ci/litmus",
                "litmus analyze . --results .build/swift-ci/litmus/run.pb --strict"
            ]
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
                == "https://github.com/g-cqd/dolly/releases/download/v0.14.2/dolly-0.14.2-linux-x86_64.tar.gz"
        )
        #expect(dolly.binaryPath(for: .macOSArm64) == "dolly-0.14.2-macos-arm64/dolly")
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
