import Foundation
import SwiftCIKit
import Testing

/// `swift-ci family repin` on three small repositories with local origins: X, A pinning X, B pinning A and X.
struct FamilyRepinTests {
    /// A family under a temporary directory: each member a repository whose origin is a bare one beside it.
    final class Fixture {
        let root: URL
        let origins: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "swift-ci-family-\(UUID().uuidString)"
            )
            root = base.appendingPathComponent("family")
            origins = base.appendingPathComponent("origins")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: origins, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        func git(_ arguments: [String], in directory: URL) throws -> String {
            try Shell.output(
                ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments,
                directory: directory,
                quiet: true
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Member `name` with `manifest` committed and pushed; its head.
        @discardableResult
        func member(_ name: String, _ manifest: String) throws -> String {
            let origin = origins.appendingPathComponent(name + ".git")
            _ = try git(["init", "-q", "--bare", "-b", "main", origin.path], in: origins)
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            _ = try git(["init", "-q", "-b", "main"], in: path)
            _ = try git(["config", "user.name", "t"], in: path)
            _ = try git(["config", "user.email", "t@t"], in: path)
            _ = try git(["config", "commit.gpgsign", "false"], in: path)
            try manifest.write(to: path.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            _ = try git(["add", "-A"], in: path)
            _ = try git(["commit", "-q", "-m", "first"], in: path)
            _ = try git(["remote", "add", "origin", origin.path], in: path)
            _ = try git(["push", "-q", "-u", "origin", "main"], in: path)
            return try git(["rev-parse", "HEAD"], in: path)
        }

        func manifest(requiring pins: [(String, String)]) -> String {
            let lines = pins.map {
                #"        .package(url: "https://github.com/g-cqd/\#($0.0).git", revision: "\#($0.1)"),"#
            }
            return
                "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(\n    name: \"p\",\n    dependencies: [\n"
                + lines.joined(separator: "\n") + "\n    ]\n)\n"
        }

        /// A new commit of X, pushed; its revision.
        func advanceX() throws -> String {
            let x = root.appendingPathComponent("X")
            try "// more\n".write(to: x.appendingPathComponent("More.swift"), atomically: true, encoding: .utf8)
            _ = try git(["add", "-A"], in: x)
            _ = try git(["commit", "-q", "-m", "more"], in: x)
            _ = try git(["push", "-q", "origin", "main"], in: x)
            return try git(["rev-parse", "HEAD"], in: x)
        }

        func pins(of name: String, at ref: String) throws -> [String: String] {
            let text = try git(["show", "\(ref):Package.swift"], in: root.appendingPathComponent(name))
            return Dictionary(uniqueKeysWithValues: FamilyManifest.pins(in: text).map { ($0.package, $0.revision) })
        }
    }

    private func family() throws -> (Fixture, String, String) {
        let fixture = try Fixture()
        let x = try fixture.member("X", fixture.manifest(requiring: []))
        let a = try fixture.member("A", fixture.manifest(requiring: [("X", x)]))
        try fixture.member("B", fixture.manifest(requiring: [("A", a), ("X", x)]))
        return (fixture, x, a)
    }

    @Test func theGraphIsReadInLevelsAndAChangeForcesItsDependentsInOrder() throws {
        let (fixture, _, _) = try family()
        let family = try Family.load(root: fixture.root)
        #expect(family.levels().map { $0.map(\.name) } == [["X"], ["A"], ["B"]])
        #expect(family.dependents(of: ["x"]).map(\.name) == ["A", "B"])
        #expect(family.dependents(of: ["a"]).map(\.name) == ["B"])
    }

    @Test func withoutPushTheCommitsStayOnALocalBranchAndNothingReachesTheOrigins() throws {
        let (fixture, _, _) = try family()
        let newX = try fixture.advanceX()
        var repin = FamilyRepin(family: try Family.load(root: fixture.root))
        var gated: [String] = []
        repin.gate = { _, member, _ in gated.append(member.name) }
        repin.log = { _ in }
        let changes = try repin.run(bumps: ["X": newX])
        #expect(changes.map(\.member) == ["A", "B"] && gated == ["A", "B"])
        let newA = try #require(changes.first?.revision)
        #expect(try fixture.pins(of: "A", at: FamilyRepin.branch) == ["x": newX])
        #expect(try fixture.pins(of: "B", at: FamilyRepin.branch) == ["a": newA, "x": newX], "B pins A's new commit")
        #expect(try fixture.pins(of: "A", at: "origin/main")["x"] != newX, "nothing pushed")
        #expect(FamilyRepin.clean(try Family.load(root: fixture.root)) == ["A", "B"])
        #expect(throws: SwiftCIError.self) {
            try Shell.output(
                ["git", "rev-parse", "-q", "--verify", FamilyRepin.branch],
                directory: fixture.root.appendingPathComponent("A"),
                quiet: true
            )
        }
    }

    @Test func withPushEachLevelReachesItsOriginAndACleanCheckoutFollows() throws {
        let (fixture, _, _) = try family()
        let newX = try fixture.advanceX()
        var repin = FamilyRepin(family: try Family.load(root: fixture.root))
        repin.push = true
        repin.gate = { _, _, _ in }
        repin.log = { _ in }
        let changes = try repin.run(bumps: ["X": newX])
        let a = fixture.root.appendingPathComponent("A")
        _ = try fixture.git(["fetch", "-q", "origin"], in: a)
        #expect(try fixture.pins(of: "A", at: "origin/main") == ["x": newX])
        #expect(
            try fixture.git(["rev-parse", "HEAD"], in: a) == changes.first?.revision,
            "the clean checkout was moved"
        )
        #expect(try fixture.pins(of: "B", at: "origin/main")["a"] == changes.first?.revision)
    }

    @Test func aPushedRepinRefusesARevisionTheOriginLacks() throws {
        let (fixture, _, _) = try family()
        let x = fixture.root.appendingPathComponent("X")
        try "// local\n".write(to: x.appendingPathComponent("Local.swift"), atomically: true, encoding: .utf8)
        _ = try fixture.git(["add", "-A"], in: x)
        _ = try fixture.git(["commit", "-q", "-m", "local only"], in: x)
        var repin = FamilyRepin(family: try Family.load(root: fixture.root))
        repin.push = true
        repin.gate = { _, _, _ in }
        #expect(throws: SwiftCIError.self) {
            try repin.run(bumps: ["X": try fixture.git(["rev-parse", "HEAD"], in: x)])
        }
    }

    @Test func everyMemberAtItsOriginBringsTheStaleOnesUpToDateAndRepinsNamedOnesToo() throws {
        let (fixture, _, _) = try family()
        let newX = try fixture.advanceX()
        let family = try Family.load(root: fixture.root)
        var all: [String: String] = [:]
        for member in family.members {
            all[member.package] = try fixture.git(["rev-parse", "origin/main"], in: member.path)
        }
        var repin = FamilyRepin(family: family)
        repin.gate = { _, _, _ in }
        repin.log = { _ in }
        let changes = try repin.run(bumps: all)
        #expect(changes.map(\.member) == ["A", "B"], "A and B pinned the old X, though all were named")
        #expect(try fixture.pins(of: "B", at: FamilyRepin.branch) == ["a": changes[0].revision, "x": newX])
    }
}
