import Foundation
import SwiftCIKit
import Testing

struct DependabotTests {
    static let repository = [
        "Package.swift", "Package.resolved", "Benchmarks/Package.swift", "Sources/Kit/Kit.swift",
        "Tests/Fixtures/Example/Package.swift", "Tests/KitTests/Fixtures/Nested/Package.swift",
        ".build/checkouts/dep/Package.swift", ".github/workflows/ci.yml", "action.yml", "setup/action.yml",
        ".github/actions/cache/action.yaml", ".build/checkouts/dep/action.yml"
    ]

    @Test func `every manifest but fixtures and build output is a swift directory, the top level first`() {
        #expect(Dependabot().swiftDirectories(files: Self.repository) == ["/", "/Benchmarks"])
    }

    @Test func `workflows and a top-level action are the top level; composite actions add their directories`() {
        #expect(Dependabot.actionDirectories(files: Self.repository) == ["/", "/.github/actions/cache", "/setup"])
        #expect(Dependabot.actionDirectories(files: ["Package.swift", "Sources/A.swift"]).isEmpty)
        #expect(Dependabot.actionDirectories(files: [".github/workflows/x.yaml"]) == ["/"])
    }

    @Test func `the file has one grouped weekly update per ecosystem`() throws {
        var dependabot = Dependabot()
        dependabot.day = "tuesday"
        let text = try #require(
            dependabot.contents(files: ["Package.swift", "Fuzz/Package.swift", ".github/workflows/ci.yml"])
        )
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).drop { $0.hasPrefix("#") }
        #expect(
            body.joined(separator: "\n") == """
                version: 2
                updates:
                  - package-ecosystem: "swift"
                    directories:
                      - "/"
                      - "/Fuzz"
                    schedule:
                      interval: "weekly"
                      day: "tuesday"
                    open-pull-requests-limit: 5
                    cooldown:
                      default-days: 7
                    groups:
                      swift-packages:
                        patterns: ["*"]
                    commit-message:
                      prefix: "build"

                  - package-ecosystem: "github-actions"
                    directories:
                      - "/"
                    schedule:
                      interval: "weekly"
                      day: "tuesday"
                    cooldown:
                      default-days: 7
                    groups:
                      github-actions:
                        patterns: ["*"]
                    commit-message:
                      prefix: "ci"

                """
        )
    }

    @Test func `nothing to update gives no file; one ecosystem alone is written alone`() throws {
        #expect(Dependabot().contents(files: ["README.md"]) == nil)
        let actions = try #require(Dependabot().contents(files: [".github/workflows/ci.yml"]))
        #expect(actions.contains("github-actions") && !actions.contains("\"swift\""))
    }

    @Test func `the configuration key decodes, and a bad weekday or an unknown key is an error`() throws {
        let off = try configuration(#"{"dependabot": {"enabled": false, "exclude": ["Examples/**"]}}"#)
        #expect(!off.dependabot.enabled && off.dependabot.exclude == ["Examples/**"] && off.dependabot.day == "monday")
        #expect(throws: SwiftCIError.self) { try configuration(#"{"dependabot": {"day": "Monday"}}"#) }
        #expect(throws: SwiftCIError.self) { try configuration(#"{"dependabot": {"weekly": true}}"#) }
        #expect(throws: SwiftCIError.self) { try configuration(#"{"dependabot": {"cooldownDays": -1}}"#) }
        let now = try #require(
            try configuration(#"{"dependabot": {"cooldownDays": 0}}"#).dependabot.contents(files: ["Package.swift"])
        )
        #expect(!now.contains("cooldown:"))
    }

    @Test func `quality checks the file first, unless it is turned off`() throws {
        let lock = ToolLock.builtIn
        let on = StepPlanner(configuration: try configuration("{}"), project: package, lock: lock)
        #expect(
            try on.steps(for: "quality", swiftFiles: [], fileExists: { _ in false }).first == .dependabot(Dependabot())
        )
        let off = StepPlanner(
            configuration: try configuration(#"{"dependabot": {"enabled": false}}"#),
            project: package,
            lock: lock
        )
        #expect(
            !(try off.steps(for: "quality", swiftFiles: [], fileExists: { _ in false }))
                .contains { if case .dependabot = $0 { true } else { false } }
        )
    }

    @Test func `drift names a missing file, a changed one, and passes the file it writes`() throws {
        let sandbox = try Sandbox([
            "Package.swift": "// swift-tools-version:6.0\n", ".github/workflows/ci.yml": "on: push\n"
        ])
        let dependabot = Dependabot()
        #expect(dependabot.drift(top: sandbox.root)?.contains("is missing") == true)
        let url = sandbox.root.appendingPathComponent(Dependabot.path)
        let written = try #require(dependabot.contents(files: Dependabot.files(top: sandbox.root)))
        try (written + "  # edited\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(dependabot.drift(top: sandbox.root)?.contains("differs") == true)
        try written.write(to: url, atomically: true, encoding: .utf8)
        #expect(dependabot.drift(top: sandbox.root) == nil)
    }
}
