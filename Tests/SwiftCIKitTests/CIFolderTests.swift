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
        #expect(files.map(\.path) == [".ci/action.json", ".github/workflows/ci.yml"])
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
        #expect(written == [".ci/action.json"] && kept == [".github/workflows/ci.yml"])
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
