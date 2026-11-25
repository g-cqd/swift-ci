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

    /// A repository with no `origin/main` (one kept local, not published) is not part of the family: it must not stop the
    /// graph of the others (seen 2026-11-24: `family graph` died with git's 128 on a local-only repository).
    /// The gate's build (2026-11-24, the owner: fewer builds, a faster repin): none where the host cannot build the member, and its
    /// products kept between runs, where a worktree is deleted after each push.
    /// A host with one toolchain installed (the VM's swiftly has 6.4.3, the members pin 6.4.0 and others) builds every member with it:
    /// that toolchain's `bin` goes first on the PATH, which swiftly's proxy and its `.swift-version` then never see.
    /// A repin changes pins and workflows, never a member's sources: the quality step over them can differ only when the tools do, that
    /// is when swift-ci's own pin moves. The gate runs it then, always when asked, never when told not to.
    /// A lock may name a revision no clone has any more (a history that was rewritten: ask's Fuzz and Conformance packages, 2026-11-24).
    /// The repin then resolves that package from its manifest again, instead of stopping on it.
    /// A member pins swift-ci in its workflows, not in a manifest: the commit there is a pin like the others, so that a repin that
    /// brings the family up to date brings its tools up too (2026-11-24: nine members used nine different swift-ci commits).
    @Test func `the swift-ci commit a workflow uses is one of the member's pins`() throws {
        let fixture = try Fixture()
        try fixture.member("Tool", fixture.manifest(requiring: []))
        let member = fixture.root.appendingPathComponent("Lib")
        let revision = String(repeating: "ab", count: 20)
        try fixture.member("Lib", fixture.manifest(requiring: []))
        let workflows = member.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try "jobs:\n  ci:\n    uses: g-cqd/swift-ci/.github/workflows/swift-ci.yml@\(revision) # swift-ci abababa\n"
            .write(
                to: workflows.appendingPathComponent("ci.yml"),
                atomically: true,
                encoding: .utf8
            )
        _ = try fixture.git(["add", "-A"], in: member)
        _ = try fixture.git(["commit", "-q", "-m", "workflow"], in: member)
        _ = try fixture.git(["push", "-q", "origin", "main"], in: member)
        let family = try Family.load(root: fixture.root)
        let lib = try #require(family.member("Lib"))
        #expect(lib.pins.contains { $0.package == "swift-ci" && $0.revision == revision })
        #expect(lib.requires.contains("swift-ci"))
    }

    @Test func `a lock naming a revision nothing has is resolved again from its manifest`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("Package.resolved")
        try "stale".write(to: lock, atomically: true, encoding: .utf8)
        var calls: [Bool] = []
        try FamilyRepin.resolve(in: directory) { _ in
            calls.append(FileManager.default.fileExists(atPath: lock.path))
            if calls.count == 1 { throw SwiftCIError("unable to read tree") }
        }
        #expect(calls == [true, false], "the second try has no lock to honour")
        // One that resolves is left as it is; one that fails with no lock to blame fails.
        calls = []
        try "kept".write(to: lock, atomically: true, encoding: .utf8)
        try FamilyRepin.resolve(in: directory) { _ in calls.append(true) }
        #expect(calls == [true] && FileManager.default.fileExists(atPath: lock.path))
        try? FileManager.default.removeItem(at: lock)
        #expect(throws: SwiftCIError.self) { try FamilyRepin.resolve(in: directory) { _ in throw SwiftCIError("no") } }
    }

    @Test func `the gate runs quality when the tools move, or when asked, and not otherwise`() {
        #expect(FamilyRepin.runsQuality(policy: nil, swiftCIMoved: true))
        #expect(!FamilyRepin.runsQuality(policy: nil, swiftCIMoved: false))
        #expect(FamilyRepin.runsQuality(policy: "when-swift-ci-moves", swiftCIMoved: true))
        #expect(FamilyRepin.runsQuality(policy: "always", swiftCIMoved: false))
        #expect(!FamilyRepin.runsQuality(policy: "off", swiftCIMoved: true))
    }

    @Test func `one installed toolchain can serve every member, whatever its swift-version file says`() {
        #expect(FamilyRepin.toolchainEnvironment(bin: nil, path: "/usr/bin") == [:])
        #expect(FamilyRepin.toolchainEnvironment(bin: "", path: "/usr/bin") == [:])
        #expect(
            FamilyRepin.toolchainEnvironment(bin: "/tc/usr/bin", path: "/usr/bin:/bin") == [
                "PATH": "/tc/usr/bin:/usr/bin:/bin"
            ]
        )
    }

    @Test func `a gate builds only what its host can build, and keeps the products between runs`() throws {
        let fixture = try Fixture()
        try fixture.member("Mac", fixture.manifest(requiring: []))
        try fixture.member("Any", fixture.manifest(requiring: []))
        let macOnly = fixture.root.appendingPathComponent("Mac")
        try FileManager.default.createDirectory(
            at: macOnly.appendingPathComponent(".ci"),
            withIntermediateDirectories: true
        )
        try #"{"project": {"linux": false}}"#
            .write(
                to: macOnly.appendingPathComponent(".ci/action.json"),
                atomically: true,
                encoding: .utf8
            )
        let family = try Family.load(root: fixture.root)
        let cache = fixture.root.appendingPathComponent(".family-repin-cache")
        let mac = try #require(family.member("Mac"))
        let any = try #require(family.member("Any"))

        #expect(
            FamilyRepin.buildCommand(for: mac, in: macOnly, scratch: cache, onLinux: true) == nil,
            "Linux cannot build it"
        )
        #expect(
            FamilyRepin.buildCommand(for: mac, in: macOnly, scratch: cache, onLinux: false)
                == ["swift", "build", "--scratch-path", cache.appendingPathComponent("Mac").path]
        )
        #expect(
            FamilyRepin.buildCommand(
                for: any,
                in: fixture.root.appendingPathComponent("Any"),
                scratch: cache,
                onLinux: true
            )
                == ["swift", "build", "--scratch-path", cache.appendingPathComponent("Any").path]
        )
        #expect(
            FamilyRepin.buildCommand(
                for: any,
                in: fixture.root.appendingPathComponent("Any"),
                scratch: nil,
                onLinux: true
            )
                == ["swift", "build"],
            "no cache asked for"
        )
    }

    @Test func `a repository with no origin is left out of the family, not an error`() throws {
        let fixture = try Fixture()
        try fixture.member("X", fixture.manifest(requiring: []))
        let local = fixture.root.appendingPathComponent("Local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        _ = try fixture.git(["init", "-q", "-b", "main"], in: local)
        try "// swift-tools-version: 6.0\n"
            .write(to: local.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let family = try Family.load(root: fixture.root)
        #expect(family.members.map(\.name) == ["X"])
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

    @Test func whatAGateLeavesInAWorktreeDoesNotStopTheRunOnceItsCommitIsPushed() throws {
        let (fixture, _, _) = try family()
        let newX = try fixture.advanceX()
        var repin = FamilyRepin(family: try Family.load(root: fixture.root))
        repin.push = true
        // As a build does: files the commit does not hold, some in folders.
        repin.gate = { tree, _, _ in
            let left = tree.appendingPathComponent("left/behind")
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try "x".write(to: left.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        }
        repin.log = { _ in }
        let changes = try repin.run(bumps: ["X": newX])
        #expect(changes.map(\.member) == ["A", "B"], "B was reached after A's worktree was put away")
        let trees = fixture.root.appendingPathComponent(".family-repin")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: trees.path)) ?? []).isEmpty)
        let listed = try fixture.git(["worktree", "list"], in: fixture.root.appendingPathComponent("A"))
        #expect(!listed.contains(".family-repin"))
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

    /// A manifest's `.package(path: "../A")` names a sibling: it orders the graph like a pin, and from the worktree it reaches A at
    /// this run's revision of it, never the clone and the work in it.
    /// SwiftPM takes a local repository only where `git rev-parse --git-dir` says `.git` or `.`: a submodule's checkout, whose
    /// `.git` is a file, is refused ("cannot clone from local directory"), and its git directory is taken.
    @Test func aMemberThatIsASubmoduleCheckoutIsMirroredAtItsGitDirectory() throws {
        let (fixture, _, _) = try family()
        let x = fixture.root.appendingPathComponent("X")
        #expect(FamilyRepin.mirrorLocation(of: x) == x.path, "a plain clone is its own mirror")
        // X made what an umbrella's submodule is: its git directory elsewhere, a `.git` file that says where.
        let modules = fixture.root.appendingPathComponent(".git/modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let moved = modules.appendingPathComponent("X")
        try FileManager.default.moveItem(at: x.appendingPathComponent(".git"), to: moved)
        try "gitdir: ../.git/modules/X\n".write(to: x.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        _ = try fixture.git(["config", "core.worktree", x.path], in: moved)
        let location = FamilyRepin.mirrorLocation(of: x)
        #expect(URL(fileURLWithPath: location).resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
        #expect(try fixture.git(["-C", location, "rev-parse", "--git-dir"], in: fixture.root) == ".")
        // And the mirrors file a repin writes for a member says so.
        let family = try Family.load(root: fixture.root)
        let a = try #require(family.member("a"))
        let files = try FamilyRepin(family: family).writeMirrors(in: a.path, member: a)
        defer { FamilyRepin(family: family).restoreMirrors(files) }
        let text = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(text.contains("modules/X\"") || text.contains("modules\\/X\""))
        #expect(!text.contains("\"mirror\":\"\(x.path)\""))
    }

    @Test func aSiblingPathDependencyOrdersTheGraphAndReachesTheSiblingAtThisRunsRevision() throws {
        let (fixture, x, _) = try family()
        let manifest = fixture.manifest(requiring: [("X", x)])
            .replacingOccurrences(of: "    ]\n)", with: "        .package(path: \"../A\"),\n    ]\n)")
        try fixture.member("U", manifest)
        try "wip\n".write(to: fixture.root.appendingPathComponent("A/LOCAL"), atomically: true, encoding: .utf8)
        let newX = try fixture.advanceX()
        var repin = FamilyRepin(family: try Family.load(root: fixture.root))
        #expect(repin.family.levels().map { $0.map(\.name) } == [["X"], ["A"], ["B", "U"]])
        var seen: [String] = []
        repin.gate = { tree, member, _ in
            guard member.name == "U" else { return }
            let sibling = tree.appendingPathComponent("../A")
            seen.append(try fixture.git(["rev-parse", "HEAD"], in: sibling))
            if FileManager.default.fileExists(atPath: sibling.appendingPathComponent("LOCAL").path) {
                seen.append("clone")
            }
        }
        repin.log = { _ in }
        let changes = try repin.run(bumps: ["x": newX])
        #expect(changes.map(\.member) == ["A", "B", "U"])
        #expect(seen == [changes[0].revision])
        #expect(FamilyRepin.clean(try Family.load(root: fixture.root)) == ["A", "B", "U"])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".family-repin").path))
    }
}
