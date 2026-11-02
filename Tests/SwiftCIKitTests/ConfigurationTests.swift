import Foundation
import SwiftCIKit
import Testing

struct ConfigurationTests {
    @Test func `an empty object is the documented defaults`() throws {
        let decoded = try configuration("{}")
        #expect(decoded == Configuration())
        #expect(decoded.swift.versions == ["6.4.1"])
        #expect(decoded.swift.matrix == [CheckID.linuxDebug])
        #expect(decoded.runners.macOS == ["macos-26"])
        #expect(decoded.quality.analyzers == ["deadwood", "dolly", "arcleak"])
        #expect(decoded.quality.formatters == .auto)
    }

    @Test func `given keys override the defaults and the rest stay`() throws {
        let decoded = try configuration(
            #"{"swift": {"versions": ["6.3.3", "6.4.1"], "environment": {"DEV": "1"}}, "runners": {"macOS": ["self-hosted", "mobile"]}}"#
        )
        #expect(decoded.swift.versions == ["6.3.3", "6.4.1"])
        #expect(decoded.swift.environment == ["DEV": "1"])
        #expect(decoded.swift.parallel)
        #expect(decoded.swift.linuxImages["nightly-main"] == "swiftlang/swift:nightly-main-noble")
        #expect(decoded.runners.macOS == ["self-hosted", "mobile"])
        #expect(decoded.runners.linux == ["ubuntu-latest"])
    }

    @Test(arguments: [
        (#"{"projetc": {}}"#, "unknown key 'projetc'"),
        (#"{"swift": {"version": ["6.4"]}}"#, "unknown key 'swift.version'"),
        (#"{"platforms": [{"name": "iOS", "sdk": "x"}]}"#, "unknown key 'platforms[0].sdk'"),
        (#"{"commands": [{"id": "x", "run": "y", "when": []}]}"#, "unknown key 'commands[0].when'")
    ])
    func `an unknown key is an error naming its path`(json: String, message: String) {
        #expect {
            try configuration(json)
        } throws: { error in
            "\(error)".contains(message)
        }
    }

    @Test func `a wrong type and an empty version list are errors`() {
        #expect(throws: (any Error).self) { try configuration(#"{"swift": {"versions": "6.4.1"}}"#) }
        #expect(throws: (any Error).self) { try configuration(#"{"swift": {"versions": []}}"#) }
        #expect(throws: (any Error).self) { try configuration(#"{"checks": {"quality": ["sometimes"]}}"#) }
        #expect(throws: (any Error).self) { try configuration(#"{"quality": {"formatters": "all"}}"#) }
    }

    @Test func `formatters are auto or an explicit list`() throws {
        #expect(try configuration(#"{"quality": {"formatters": "auto"}}"#).quality.formatters == .auto)
        #expect(
            try configuration(#"{"quality": {"formatters": ["swiftlint"]}}"#).quality.formatters == .only([.swiftLint])
        )
    }

    @Test func `the macOS toolchain is the primary version, a given one, or the selected Xcode's`() throws {
        #expect(try configuration("{}").swift.macOSVersion == "6.4.1")
        #expect(try configuration(#"{"swift": {"macOS": "xcode"}}"#).swift.macOSVersion == nil)
        #expect(try configuration(#"{"swift": {"macOS": "6.3.3"}}"#).swift.macOSVersion == "6.3.3")
    }

    @Test func `linux images come from the template unless named`() throws {
        let toolchain = try configuration(#"{"swift": {"linuxImages": {"6.5": "custom:6.5"}}}"#).swift
        #expect(toolchain.image(for: "6.4.1") == "swift:6.4.1-noble")
        #expect(toolchain.image(for: "6.5") == "custom:6.5")
        #expect(toolchain.image(for: "nightly-main") == "swiftlang/swift:nightly-main-noble")
    }

    @Test func `a section given in part, and each list element, take the rest of their defaults`() throws {
        let decoded = try configuration(
            #"{"release": {"executables": ["tool"]}, "documentation": {"targets": ["Kit"]}, "commands": [{"id": "x", "run": "y"}]}"#
        )
        #expect(decoded.release?.notes == "release-notes/{tag}.md")
        #expect(decoded.documentation?.warningsAsErrors == true)
        #expect(decoded.commands.first?.os == .linux)
        #expect(decoded.commands.first?.cadence == Array(Trigger.everyChange).sorted())
        #expect(try configuration("{}").release == nil)
        #expect {
            try configuration(#"{"documentation": {}}"#)
        } throws: { "\($0)".contains("documentation.targets: required") }
    }

    @Test func `the keys a map holds are the user's`() throws {
        let decoded = try configuration(#"{"checks": {"anything": []}, "swift": {"environment": {"ANY_NAME": "1"}}}"#)
        #expect(decoded.checks["anything"] == [])
        #expect(decoded.swift.environment["ANY_NAME"] == "1")
    }

    @Test func `a missing file is the defaults`() throws {
        let sandbox = try Sandbox()
        #expect(try Configuration.load(root: sandbox.root) == Configuration())
    }
}

struct EventTests {
    @Test(arguments: [
        ("push", "refs/heads/main", Trigger.push),
        ("push", "refs/tags/v1.2.0", .tag),
        ("pull_request", "refs/pull/3/merge", .pullRequest),
        ("merge_group", "refs/heads/gh-readonly-queue/main/pr-3", .mergeQueue),
        ("schedule", "refs/heads/main", .nightly),
        ("workflow_dispatch", "refs/heads/main", .dispatch)
    ])
    func `GitHub events map to triggers`(name: String, ref: String, trigger: Trigger) throws {
        #expect(try Event.gitHub(eventName: name, ref: ref).trigger == trigger)
    }

    @Test func `a tag's name, and an unknown event`() throws {
        #expect(try Event.gitHub(eventName: "push", ref: "refs/tags/v0.4.6").tagName == "v0.4.6")
        #expect(try Event.gitHub(eventName: "push", ref: "refs/heads/main").tagName == nil)
        #expect(throws: SwiftCIError.self) { try Event.gitHub(eventName: "issues", ref: "") }
    }
}

struct GlobTests {
    @Test(arguments: [
        ("*.md", "README.md", true), ("*.md", "docs/guide/a.md", true), ("*.md", "README.markdown", false),
        ("docs/**", "docs/a/b/c.txt", true), ("docs/**", "docs", false), ("docs/**", "Sources/docs/x", false),
        ("**/Fixtures/**", "Tests/A/Fixtures/x.swift", true), ("**/Fixtures/**", "Fixtures/x.swift", true),
        ("**/Fixtures/**", "Tests/FixturesX/x.swift", false), ("Sources/*.swift", "Sources/a.swift", true),
        ("Sources/*.swift", "Sources/x/a.swift", false), ("a?c", "abc", true), ("a?c", "a/c", false),
        ("LICENSE", "LICENSE", true), ("LICENSE", "x/LICENSE", true), ("/LICENSE", "x/LICENSE", false),
        ("release-notes/**", "release-notes/v1.md", true), ("**", "anything/at/all", true)
    ])
    func `patterns match as .gitignore spells them`(pattern: String, path: String, expected: Bool) {
        #expect(Glob(pattern).matches(path) == expected)
    }
}
