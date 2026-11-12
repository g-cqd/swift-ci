public import Foundation

/// A repin of the family (`swift-ci family repin`, the owner's option A, 2026-11-12): the packages a change forces a pin commit in,
/// level by level. Each is changed in a worktree off its `origin/main` beside the person's checkout, which is never touched while
/// it has work of its own: its manifests' pins rewritten, its tracked `Package.resolved` files resolved again against the
/// family's local clones (a mirrors file the run removes), its gate run, and a commit made. With `push`, each commit is pushed to
/// `origin/main` before the next level starts, and the umbrella's submodules follow; without, the commits stay on a local
/// `family-repin` branch of each repository, which is option E: the family built at the new revisions before anything is pinned.
public struct FamilyRepin {
    /// What a repin did to one member.
    public struct Change: Sendable, Equatable {
        public let member: String
        public let revision: String
        public let moved: [String: String]
    }

    public let family: Family
    public var push = false
    /// Runs a member's gate in its worktree, with the environment given; the default builds it and runs its swift-ci quality.
    public var gate: (URL, Family.Member, [String: String]) throws -> Void = FamilyRepin.defaultGate
    public var log: (String) -> Void = { print($0) }
    /// The branch the commits are made on; with `push` it is deleted once pushed.
    public static let branch = "family-repin"

    public init(family: Family) { self.family = family }

    /// Where `name`'s worktree goes: beside the clones, as `.repin-name`, so a manifest's `.package(path: "../X")` still reaches
    /// the sibling clone.
    static func worktree(_ name: String, in family: Family) -> URL {
        family.root.appendingPathComponent(".repin-" + name)
    }

    /// Repins every member whose pins `bumps` (package to revision) and the commits of this run make stale, in order; returns what
    /// it changed.
    public mutating func run(bumps: [String: String]) throws -> [Change] {
        var revisions = Dictionary(uniqueKeysWithValues: bumps.map { ($0.key.lowercased(), $0.value) })
        if push { try requirePushed(revisions) }
        var changes: [Change] = []
        // Every member in level order whose pins differ from this run's revisions: those `bumps` force, and a named one too when
        // it pins something stale (bringing the whole family up to date names every member at its origin).
        for member in family.levels().joined() {
            let moved = member.pins.reduce(into: [String: String]()) { moved, pin in
                if let revision = revisions[pin.package], revision != pin.revision { moved[pin.package] = revision }
            }
            guard !moved.isEmpty else { continue }
            let revision = try repin(member, moving: moved, all: revisions)
            revisions[member.package] = revision
            changes.append(Change(member: member.name, revision: revision, moved: moved))
        }
        if push, !changes.isEmpty { try updateUmbrella(bumps: bumps, changes: changes) }
        return changes
    }

    /// A pushed run pins only what the remote has.
    private func requirePushed(_ revisions: [String: String]) throws {
        for (package, revision) in revisions {
            guard let member = family.member(package) else {
                throw SwiftCIError("no member \(package) in \(family.root.path)")
            }
            let pushed = try? Shell.output(
                ["git", "merge-base", "--is-ancestor", revision, "origin/main"],
                directory: member.path,
                quiet: true
            )
            guard pushed != nil else {
                throw SwiftCIError(
                    "\(member.name) \(revision.prefix(7)) is not on origin/main: push it first, or repin without --push"
                )
            }
        }
    }

    /// One member repinned in a worktree: its new revision.
    private func repin(_ member: Family.Member, moving moved: [String: String], all revisions: [String: String]) throws
        -> String
    {
        let summary = moved.sorted { $0.key < $1.key }
            .map { "\(family.member($0.key)?.name ?? $0.key) \($0.value.prefix(7))" }
        log("\(member.name): \(summary.joined(separator: ", "))")
        let tree = Self.worktree(member.name, in: family)
        try Shell.run(["git", "fetch", "-q", "origin"], directory: member.path)
        try freshWorktree(tree, of: member, ["-B", Self.branch, tree.path, "origin/main"])
        try rewrite(tree, member: member, moved: moved)
        let mirrors = try writeMirrors(in: tree, member: member)
        try resolveLocks(tree, member: member)
        var environment: [String: String] = [:]
        if revisions["swift-ci"] != nil, let swiftCI = family.member("swift-ci") {
            environment["SWIFT_CI_SOURCE"] = try sourceTree(of: swiftCI, at: revisions["swift-ci"] ?? "").path
        }
        do {
            try gate(tree, member, environment)
        } catch {
            restoreMirrors(mirrors)
            throw SwiftCIError("\(member.name)'s gate failed in \(tree.path), left for a look: \(error)")
        }
        restoreMirrors(mirrors)
        try Shell.run(["git", "add", "-u"], directory: tree)
        try Shell.run(
            ["git", "commit", "-q", "-m", "build: \(summary.joined(separator: ", ")) (swift-ci family repin)"],
            directory: tree
        )
        let revision = try Shell.output(["git", "rev-parse", "HEAD"], directory: tree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if push {
            try Shell.run(["git", "push", "-q", "origin", "HEAD:main"], directory: tree)
            try Shell.run(["git", "worktree", "remove", tree.path], directory: member.path)
            try Shell.run(["git", "branch", "-D", "-q", Self.branch], directory: member.path)
            fastForward(member)
        }
        return revision
    }

    /// The member's manifests at their new pins, and its workflows at swift-ci's new commit when that moved.
    private func rewrite(_ tree: URL, member: Family.Member, moved: [String: String]) throws {
        for manifest in member.manifests {
            try rewrite(tree.appendingPathComponent(manifest)) { FamilyManifest.rewriting($0, to: moved) }
        }
        guard let swiftCI = moved["swift-ci"] else { return }
        let workflows = tree.appendingPathComponent(".github/workflows")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: workflows.path)) ?? []
        where name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            try rewrite(workflows.appendingPathComponent(name)) { FamilyManifest.rewritingSwiftCI($0, to: swiftCI) }
        }
    }
}
