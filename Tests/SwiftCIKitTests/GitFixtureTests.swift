import Foundation
import SwiftCIKit
import Testing

struct GitFixtureTests {
    static let commit = "ce08da1ddb075d1c7596d663c7fcba9a2ae02c5c"

    @Test func `a command fetches repositories at pinned commits before the checks that need them`() throws {
        let json = #"""
            {"commands": [{"id": "suites", "title": "Fixtures · Conformance Suites", "before": ["macos-debug"],
              "git": [{"git": "https://github.com/toml-lang/toml-test", "commit": "\#(Self.commit)", "into": ".build/fixtures/toml-test"}]}]}
            """#
        let planner = StepPlanner(configuration: try configuration(json), project: package, lock: .builtIn)
        let steps = try planner.steps(for: CheckID.macOSDebug)
        #expect(
            steps.first
                == .git(
                    title: "Fixtures · Conformance Suites",
                    fixtures: [
                        GitFixture(
                            git: "https://github.com/toml-lang/toml-test",
                            commit: Self.commit,
                            into: ".build/fixtures/toml-test"
                        )
                    ]
                )
        )
        #expect(throws: SwiftCIError.self) {
            try configuration(
                #"{"commands": [{"id": "s", "git": [{"git": "https://x", "commit": "c", "into": "a", "ref": "main"}]}]}"#
            )
        }
    }

    @Test func `a fixture needs an https URL, a full commit and a path inside the root`() {
        let good = GitFixture(git: "https://github.com/a/b", commit: Self.commit, into: ".build/fixtures/b")
        #expect(good.problem() == nil)
        var cases: [GitFixture] = []
        for git in ["http://github.com/a/b", "git@github.com:a/b", "https://", "/tmp/repo"] {
            cases.append(GitFixture(git: git, commit: Self.commit, into: "f"))
        }
        for commit in ["ce08da1", Self.commit.uppercased(), String(repeating: "g", count: 40), Self.commit + "0"] {
            cases.append(GitFixture(git: good.git, commit: commit, into: "f"))
        }
        for into in ["", "/tmp/f", "../f", "a/../f", "a//f", "./f", "f/", ".git/f", ".ci/f"] {
            cases.append(GitFixture(git: good.git, commit: Self.commit, into: into))
        }
        for fixture in cases {
            #expect(fixture.problem() != nil, "\(fixture)")
        }
    }

    @Test func `the plan refuses a command with two actions, a bad fixture, none, or two in one directory`() {
        let fixture = #"{"git": "https://github.com/a/b", "commit": "\#(Self.commit)", "into": "f"}"#
        let bad = #"{"git": "https://github.com/a/b", "commit": "main", "into": "f"}"#
        for commands in [
            #"[{"id": "s", "run": "x", "git": [\#(fixture)]}]"#,
            #"[{"id": "s", "tla": {}, "git": [\#(fixture)]}]"#,
            #"[{"id": "s", "git": [\#(bad)]}]"#,
            #"[{"id": "s", "git": []}]"#,
            #"[{"id": "s", "git": [\#(fixture), \#(fixture)]}]"#
        ] {
            #expect(throws: SwiftCIError.self) {
                _ = try Planner(configuration: configuration("{\"commands\":\(commands)}"), project: package)
                    .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
            }
        }
    }

    @Test func `a fetch copies exactly the pinned commit without history, once, and replaces another commit`() throws {
        let origin = try Sandbox(["README": "one\n"])
        let git = { (arguments: [String]) in try Shell.output(["git", "-C", origin.root.path] + arguments, quiet: true)
        }
        _ = try git(["init", "-q"])
        _ = try git(["add", "README"])
        _ = try git(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "one"])
        let first = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try "two\n".write(to: origin.root.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        _ = try git(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qam", "two"]
        )

        let project = try Sandbox()
        var executor = Executor(root: project.root)
        // A local path stands in for the https URL the configuration requires.
        let fixture = GitFixture(git: origin.root.path, commit: first, into: ".build/fixtures/origin")
        try executor.run([.git(title: "fixtures", fixtures: [fixture])])
        let copy = project.root.appendingPathComponent(".build/fixtures/origin")
        #expect(try String(contentsOf: copy.appendingPathComponent("README"), encoding: .utf8) == "one\n")
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent(".git").path))
        #expect(try String(contentsOf: copy.appendingPathComponent(GitFixture.stamp), encoding: .utf8) == first + "\n")

        // Same commit: nothing is fetched, so a local change survives.
        try "local\n".write(to: copy.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try executor.run([.git(title: "fixtures", fixtures: [fixture])])
        #expect(try String(contentsOf: copy.appendingPathComponent("README"), encoding: .utf8) == "local\n")

        // Another commit replaces the copy; a commit the repository lacks fails and leaves no partial copy.
        let second = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try executor.run([
            .git(title: "fixtures", fixtures: [GitFixture(git: fixture.git, commit: second, into: fixture.into)])
        ])
        #expect(try String(contentsOf: copy.appendingPathComponent("README"), encoding: .utf8) == "two\n")
        let missing = GitFixture(
            git: fixture.git,
            commit: String(repeating: "a", count: 40),
            into: ".build/fixtures/none"
        )
        #expect(throws: SwiftCIError.self) { try executor.run([.git(title: "fixtures", fixtures: [missing])]) }
        let left = try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path)
        #expect(left == ["origin"])
    }
}
