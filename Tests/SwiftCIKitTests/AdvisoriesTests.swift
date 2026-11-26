import Foundation
import Testing

@testable import SwiftCIKit

struct AdvisoriesTests {
    /// swift-crypto's own advisories as GitHub published them, ranges written as their authors did.
    struct Table: AdvisorySource {
        var calls = Calls()
        final class Calls: @unchecked Sendable { var repositories: [String] = [] }

        func advisories(repository: String, identity: String) throws -> [Advisory] {
            calls.repositories.append(repository)
            guard repository == "apple/swift-crypto" else { return [] }
            return [
                Advisory(
                    id: "GHSA-c24m-vphm-p22w",
                    severity: "medium",
                    summary: "Scrypt maxMemory",
                    url: "u1",
                    ranges: [.init(range: ">= 4.0.0, <= 5.1.1", patched: "5.1.2")]
                ),
                Advisory(
                    id: "GHSA-rch3-xxjq-365j",
                    severity: "critical",
                    summary: "X25519 low-order keys",
                    url: "u2",
                    ranges: [.init(range: "<=5.1.1", patched: "5.1.2")]
                ),
                Advisory(
                    id: "GHSA-9m44-rr2w-ppp7",
                    severity: "medium",
                    summary: "old",
                    url: "u3",
                    ranges: [.init(range: "4.0.0 - 4.3.0", patched: "4.3.1")]
                )
            ]
        }
    }

    static func resolved(_ pins: [(String, String, String?)]) -> String {
        let entries = pins.map { identity, location, version in
            let state =
                version.map { #""version": "\#($0)", "revision": "\#(String(repeating: "a", count: 40))""# }
                ?? #""branch": "main", "revision": "\#(String(repeating: "b", count: 40))""#
            return
                #"{"identity": "\#(identity)", "kind": "remoteSourceControl", "location": "\#(location)", "state": {\#(state)}}"#
        }
        return #"{"originHash": "x", "pins": [\#(entries.joined(separator: ", "))], "version": 3}"#
    }

    @Test func `ranges as advisories write them`() {
        #expect(Advisories.contains(">= 4.0.0, <= 5.1.1", "5.1.1") == true)
        #expect(Advisories.contains(">= 4.0.0, <= 5.1.1", "5.1.2") == false)
        #expect(Advisories.contains(">= 4.0.0, <= 5.1.1", "3.9.9") == false)
        #expect(Advisories.contains("<=5.1.1", "5.1.0") == true)
        #expect(
            Advisories.contains("4.0.0 - 4.3.0", "4.3.0") == true
                && Advisories.contains("4.0.0 - 4.3.0", "4.3.1") == false
        )
        #expect(Advisories.contains("< 1.45.0", "1.44.9") == true && Advisories.contains("= 1.2.3", "1.2.3") == true)
        #expect(Advisories.contains("< 2.0.0", "2.0.0-beta.1") == true)
        #expect(Advisories.contains("about 5", "5.0.0") == nil && Advisories.contains("< 5.0.0", "main") == nil)
    }

    @Test func `GitHub locations, HTTPS and SSH, with or without .git; elsewhere none`() {
        #expect(Advisories.gitHubRepository("https://github.com/apple/swift-crypto.git") == "apple/swift-crypto")
        #expect(Advisories.gitHubRepository("git@github.com:Apple/Swift-NIO.git") == "apple/swift-nio")
        #expect(Advisories.gitHubRepository("https://github.com/apple/swift-crypto/") == "apple/swift-crypto")
        #expect(Advisories.gitHubRepository("https://gitlab.com/o/r.git") == nil)
        #expect(Advisories.gitHubRepository("https://github.com/only-owner") == nil)
    }

    @Test func `a pin in a range is a finding; each repository is asked once; revision pins are listed`() throws {
        let resolved = Self.resolved([
            ("swift-crypto", "https://github.com/apple/swift-crypto.git", "5.1.1"),
            ("swift-nio", "https://github.com/apple/swift-nio.git", "2.100.0"),
            ("aemi", "https://github.com/Aemi-Studio/aemi.git", nil)
        ])
        let sandbox = try Sandbox(["Package.resolved": resolved, "Benchmarks/Package.resolved": resolved])
        let table = Table()
        let report = try Advisories.check(
            top: sandbox.root,
            files: ["Package.resolved", "Benchmarks/Package.resolved"],
            source: table
        )
        #expect(report.findings.map(\.id) == ["GHSA-c24m-vphm-p22w", "GHSA-rch3-xxjq-365j"])
        #expect(report.findings.allSatisfy { $0.files == ["Package.resolved", "Benchmarks/Package.resolved"] })
        #expect(report.checked == ["swift-crypto 5.1.1", "swift-nio 2.100.0"])
        #expect(report.unchecked == ["aemi"])
        #expect(table.calls.repositories == ["apple/swift-crypto", "apple/swift-nio"])
        #expect(report.findings[1].description.contains("GHSA-rch3-xxjq-365j critical [<=5.1.1, fixed in 5.1.2]"))
    }

    @Test func `a fixed version has no finding`() throws {
        let sandbox = try Sandbox([
            "Package.resolved": Self.resolved([("swift-crypto", "https://github.com/apple/swift-crypto", "5.2.0")])
        ])
        #expect(try Advisories.check(top: sandbox.root, files: ["Package.resolved"], source: Table()).findings.isEmpty)
    }

    @Test func `a version 1 lockfile is read too`() throws {
        let v1 =
            #"{"object": {"pins": [{"package": "Crypto", "repositoryURL": "https://github.com/apple/swift-crypto.git", "state": {"branch": null, "revision": "r", "version": "5.0.0"}}]}, "version": 1}"#
        let pins = try Advisories.pins(resolved: Data(v1.utf8), file: "Package.resolved")
        #expect(
            pins == [
                .init(
                    identity: "crypto",
                    location: "https://github.com/apple/swift-crypto.git",
                    version: "5.0.0",
                    file: "Package.resolved"
                )
            ]
        )
    }

    @Test func `GitHub's answers: withdrawn and other packages' entries are dropped, both patched spellings read`()
        throws
    {
        let own: [String: Any] = [
            "ghsa_id": "GHSA-1", "severity": "high", "summary": "s", "html_url": "h", "withdrawn_at": NSNull(),
            "vulnerabilities": [
                ["package": ["name": "swift-crypto"], "vulnerable_version_range": "< 2", "patched_versions": "2.0.0"]
            ]
        ]
        #expect(GitHubAdvisories.advisory(own, names: nil)?.ranges == [.init(range: "< 2", patched: "2.0.0")])
        var withdrawn = own
        withdrawn["withdrawn_at"] = "2026-01-01T00:00:00Z"
        #expect(GitHubAdvisories.advisory(withdrawn, names: nil) == nil)
        let database: [String: Any] = [
            "ghsa_id": "GHSA-2",
            "vulnerabilities": [
                [
                    "package": ["name": "@capacitor/ios"], "vulnerable_version_range": "< 9",
                    "first_patched_version": "9"
                ],
                [
                    "package": ["name": "github.com/apple/swift-nio"], "vulnerable_version_range": "< 2.100.0",
                    "first_patched_version": ["identifier": "2.100.0"]
                ]
            ]
        ]
        let advisory = GitHubAdvisories.advisory(database, names: ["github.com/apple/swift-nio", "swift-nio"])
        #expect(advisory?.ranges == [.init(range: "< 2.100.0", patched: "2.100.0")])
        #expect(GitHubAdvisories.advisory(database, names: ["swift-log"]) == nil)
    }

    @Test func `a missing repository has no advisories; a failure stops the check, naming the missing token`() throws {
        let gone = GitHubAdvisories(token: nil) { _ in (404, Data()) }
        #expect(try gone.advisories(repository: "o/r", identity: "r").isEmpty)
        let denied = GitHubAdvisories(token: nil) { _ in (401, Data()) }
        #expect(throws: SwiftCIError.self) { try denied.advisories(repository: "o/r", identity: "r") }
        do {
            _ = try denied.advisories(repository: "o/r", identity: "r")
        } catch {
            #expect("\(error)".contains("set GITHUB_TOKEN"))
        }
    }

    @Test func `the plan looks advisories up on every trigger, skipped runs included, unless narrowed`() throws {
        let planner = Planner(configuration: try configuration("{}"), project: package)
        for trigger in Trigger.allCases {
            #expect(
                try planner.plan(event: Event(trigger: trigger, ref: "refs/heads/main"), changedFiles: nil).advisories
            )
        }
        let idle = try planner.plan(
            event: Event(trigger: .nightly, ref: "refs/heads/main"),
            changedFiles: nil,
            hoursSinceLastCommit: 500
        )
        #expect(idle.skipped != nil && idle.advisories)
        let narrowed = Planner(
            configuration: try configuration(#"{"checks": {"advisories": ["nightly"]}}"#),
            project: package
        )
        #expect(try !narrowed.plan(event: Event(trigger: .push, ref: "refs/heads/main"), changedFiles: nil).advisories)
        #expect(
            try narrowed.plan(event: Event(trigger: .nightly, ref: "refs/heads/main"), changedFiles: nil).advisories
        )
    }

    @Test func `run advisories is one step, skipping fixtures' lockfiles`() throws {
        let planner = StepPlanner(configuration: try configuration("{}"), project: package, lock: .builtIn)
        #expect(try planner.steps(for: CheckID.advisories) == [.advisories(exclude: ["**/Fixtures/**", ".build/**"])])
    }
}
