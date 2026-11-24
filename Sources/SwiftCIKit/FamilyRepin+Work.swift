public import Foundation

extension FamilyRepin {
    /// Where SwiftPM is sent for the clone at `path`: the checkout, or, for a submodule's checkout (its `.git` is a file that
    /// says where the git directory is, as under an umbrella repository), that git directory. SwiftPM takes a local
    /// repository only where `git rev-parse --git-dir` answers `.git` or `.`, and refuses a submodule's checkout ("cannot
    /// clone from local directory"); the git directory holds the same commits, the ones not pushed yet included.
    public static func mirrorLocation(of path: URL) -> String {
        var isDirectory: ObjCBool = false
        let marker = path.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory), !isDirectory.boolValue,
            let directory = try? Shell.output(["git", "rev-parse", "--absolute-git-dir"], directory: path, quiet: true)
        else { return path.path }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? path.path : trimmed
    }

    /// Mirrors files in each of `member`'s package directories pointing the family at its local clones, where a commit of this
    /// run is before it is pushed; returns them, to be removed or restored before the commit.
    public func writeMirrors(in tree: URL, member: Family.Member) throws -> [URL] {
        var entries: [[String: String]] = []
        let owners = Dictionary(grouping: family.members.flatMap(\.pins), by: \.package)
            .mapValues { Set($0.map(\.owner)) }
        for other in family.members {
            let mirror = Self.mirrorLocation(of: other.path)
            for owner in owners[other.package] ?? ["g-cqd"] {
                for suffix in ["", ".git"] {
                    entries.append([
                        "original": "https://github.com/\(owner)/\(other.name)\(suffix)", "mirror": mirror
                    ])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["object": entries, "version": 1], options: [.sortedKeys])
        var written: [URL] = []
        for manifest in member.manifests {
            let directory = tree.appendingPathComponent(manifest).deletingLastPathComponent()
            let file = directory.appendingPathComponent(".swiftpm/configuration/mirrors.json")
            let tracked = FileManager.default.fileExists(atPath: file.path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if tracked { try FileManager.default.copyItem(at: file, to: file.appendingPathExtension("family-repin")) }
            try data.write(to: file)
            written.append(file)
        }
        return written
    }

    /// Puts back the mirrors files a repository had, and removes those it did not.
    public func restoreMirrors(_ files: [URL]) {
        for file in files {
            let saved = file.appendingPathExtension("family-repin")
            try? FileManager.default.removeItem(at: file)
            if FileManager.default.fileExists(atPath: saved.path) {
                try? FileManager.default.moveItem(at: saved, to: file)
            }
        }
    }

    /// Each tracked `Package.resolved` of `member` resolved again at the new pins.
    func resolveLocks(_ tree: URL, member: Family.Member) throws {
        for manifest in member.manifests {
            let directory = tree.appendingPathComponent(manifest).deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.resolved").path)
            else { continue }
            try Shell.run(
                ["swift", "package", "resolve"],
                environment: Self.toolchainEnvironment(),
                directory: directory
            )
        }
    }

    /// Each tracked `Package.resolved` of `member` with the pins its resolve took through the mirrors recorded as remote again.
    func recordPinsAsRemote(_ tree: URL, member: Family.Member) throws {
        for manifest in member.manifests {
            let resolved = tree.appendingPathComponent(manifest).deletingLastPathComponent()
                .appendingPathComponent("Package.resolved")
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }
            try rewrite(resolved, FamilyManifest.remoteKinds)
        }
    }

    /// A checkout of swift-ci at `revision`, for a gate's `.ci/swift-ci` to build when swift-ci itself moved in this run.
    func sourceTree(of swiftCI: Family.Member, at revision: String) throws -> URL {
        let tree = Self.worktree("swift-ci-source", in: family)
        try freshWorktree(tree, of: swiftCI, ["--detach", tree.path, revision])
        return tree
    }

    /// The person's checkout moved to the pushed commit when it is on `main`, clean, and has nothing of its own; left as it is
    /// otherwise, and said.
    func fastForward(_ member: Family.Member) {
        let branch = (try? Shell.output(["git", "branch", "--show-current"], directory: member.path, quiet: true)) ?? ""
        let clean =
            (try? Shell.output(["git", "status", "--porcelain"], directory: member.path, quiet: true))?.isEmpty == true
        let behind =
            (try? Shell.output(
                ["git", "merge-base", "--is-ancestor", "HEAD", "origin/main"],
                directory: member.path,
                quiet: true
            )) != nil
        guard branch.trimmingCharacters(in: .whitespacesAndNewlines) == "main", clean, behind,
            (try? Shell.run(["git", "merge", "-q", "--ff-only", "origin/main"], directory: member.path)) != nil
        else {
            log("\(member.name): its checkout has work of its own and is left as it is; origin/main has the pin")
            return
        }
    }

    /// The umbrella's submodules at the new revisions, committed and pushed, when the family's directory is one.
    func updateUmbrella(bumps: [String: String], changes: [Change]) throws {
        guard FileManager.default.fileExists(atPath: family.root.appendingPathComponent(".gitmodules").path) else {
            return
        }
        var moved: [(String, String)] = bumps.compactMap { package, revision in
            family.member(package).map { ($0.name, revision) }
        }
        moved += changes.map { ($0.member, $0.revision) }
        for (name, revision) in moved {
            try Shell.run(["git", "update-index", "--cacheinfo", "160000,\(revision),\(name)"], directory: family.root)
        }
        let summary = moved.map { "\($0.0) \($0.1.prefix(7))" }.joined(separator: ", ")
        try Shell.run(["git", "commit", "-q", "-m", "family: \(summary)"], directory: family.root)
        try Shell.run(["git", "push", "-q", "origin", "HEAD:main"], directory: family.root)
    }

    /// A member's gate: it builds where this host can build it, then its swift-ci quality runs, as its CI runs it. A member whose
    /// configuration says `project.linux: false` is not built on Linux (its macOS CI builds it); its build products are kept
    /// between runs, in `.family-repin-cache` beside the worktrees, so a repin recompiles what its new pins changed and not
    /// the whole member again (`SWIFT_CI_FAMILY_CACHE=off` builds in the worktree, as before).
    public static func defaultGate(_ tree: URL, _ member: Family.Member, _ environment: [String: String]) throws {
        let environment = environment.merging(toolchainEnvironment()) { _, toolchain in toolchain }
        if let build = buildCommand(for: member, in: tree, scratch: cacheDirectory(of: tree)) {
            try Shell.run(build, environment: environment, directory: tree)
        }
        if member.package == "swift-ci" {
            try Shell.run(["swift", "run", "swift-ci", "run", "quality"], environment: environment, directory: tree)
        } else if FileManager.default.isExecutableFile(atPath: tree.appendingPathComponent(".ci/swift-ci").path) {
            try Shell.run([".ci/swift-ci", "run", "quality"], environment: environment, directory: tree)
        }
    }

    /// The environment that makes one installed toolchain serve every member: `SWIFT_CI_FAMILY_TOOLCHAIN_BIN` (the `usr/bin` of
    /// a toolchain, such as swiftly's `~/.local/share/swiftly/toolchains/6.4.3/usr/bin`) first on the PATH. Without it the
    /// `swift` found is used, and each member's `.swift-version` asks swiftly for its own toolchain, which a host that has
    /// one installed lacks.
    public static func toolchainEnvironment(
        bin: String? = ProcessInfo.processInfo.environment["SWIFT_CI_FAMILY_TOOLCHAIN_BIN"],
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [String: String] {
        guard let bin, !bin.isEmpty else { return [:] }
        return ["PATH": path.isEmpty ? bin : bin + ":" + path]
    }

    /// Where the build products of members are kept between runs: beside `.family-repin`; nil when turned off.
    static func cacheDirectory(of tree: URL) -> URL? {
        if ProcessInfo.processInfo.environment["SWIFT_CI_FAMILY_CACHE"] == "off" { return nil }
        return tree.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".family-repin-cache")
    }

    /// The build a gate runs for `member` in `tree`, or nil when this host cannot build it: `swift build`, its products in
    /// `scratch/<member>` when there is a scratch directory.
    public static func buildCommand(
        for member: Family.Member,
        in tree: URL,
        scratch: URL?,
        onLinux: Bool = FamilyRepin.hostIsLinux
    ) -> [String]? {
        if onLinux, let configuration = try? Configuration.load(root: tree), configuration.project.linux == false {
            return nil
        }
        var command = ["swift", "build"]
        if let scratch { command += ["--scratch-path", scratch.appendingPathComponent(member.name).path] }
        return command
    }

    public static var hostIsLinux: Bool {
        #if os(Linux)
            true
        #else
            false
        #endif
    }

    /// Removes what runs without `push` left: each member's worktree under `.family-repin` and its `family-repin` branch;
    /// returns the members it cleaned.
    public static func clean(_ family: Family) -> [String] {
        var cleaned: [String] = []
        for member in family.members {
            let tree = worktree(member.name, in: family)
            let hadTree = FileManager.default.fileExists(atPath: tree.path)
            if hadTree { try? Shell.run(["git", "worktree", "remove", "--force", tree.path], directory: member.path) }
            let hadBranch =
                (try? Shell.output(["git", "rev-parse", "-q", "--verify", branch], directory: member.path, quiet: true))
                != nil
            if hadBranch { try? Shell.run(["git", "branch", "-D", "-q", branch], directory: member.path) }
            if hadTree || hadBranch { cleaned.append(member.name) }
        }
        let source = worktree("swift-ci-source", in: family)
        if let swiftCI = family.member("swift-ci"), FileManager.default.fileExists(atPath: source.path) {
            try? Shell.run(["git", "worktree", "remove", "--force", source.path], directory: swiftCI.path)
        }
        try? FileManager.default.removeItem(at: family.root.appendingPathComponent(".family-repin"))
        return cleaned
    }

    /// Removes the worktree of a member whose commit is pushed. What its gate left there (a build's folders, which something
    /// may still be writing to) must not stop the run, which has other members to reach: forced, then the folder removed by
    /// hand and git told to forget it. One that stays is said, and `family clean` removes it.
    func putAway(_ tree: URL, of member: Family.Member) {
        if (try? Shell.output(["git", "worktree", "remove", "--force", tree.path], directory: member.path, quiet: true))
            != nil
        {
            return
        }
        for _ in 0 ..< 3 where FileManager.default.fileExists(atPath: tree.path) {
            try? FileManager.default.removeItem(at: tree)
        }
        _ = try? Shell.output(["git", "worktree", "prune"], directory: member.path, quiet: true)
        if FileManager.default.fileExists(atPath: tree.path) {
            log("\(member.name): its worktree at \(tree.path) could not be removed; `family clean` removes it")
        }
    }

    /// A worktree of `member` at `tree`, made anew: `arguments` follow `git worktree add -q`.
    func freshWorktree(_ tree: URL, of member: Family.Member, _ arguments: [String]) throws {
        if FileManager.default.fileExists(atPath: tree.path) {
            try? Shell.run(["git", "worktree", "remove", "--force", tree.path], directory: member.path)
        }
        try Shell.run(["git", "worktree", "add", "-q"] + arguments, directory: member.path)
    }

    /// `file` rewritten by `change`, written only when that changed it.
    func rewrite(_ file: URL, _ change: (String) -> String) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let rewritten = change(text)
        if rewritten != text { try rewritten.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Each sibling `member` requires by path, checked out beside its worktree at this run's revision of it (its origin/main when
    /// the run has none), so the gate builds what the origins will hold, never a clone and the work in it.
    func checkOutSiblings(of member: Family.Member, at revisions: [String: String]) throws {
        for name in member.siblings {
            guard let sibling = family.member(name) else { continue }
            let tree = Self.worktree(sibling.name, in: family)
            try freshWorktree(tree, of: sibling, ["--detach", tree.path, revisions[sibling.package] ?? "origin/main"])
        }
    }
}
