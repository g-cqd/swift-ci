public import Foundation

/// The family under one directory (`swift-ci family`): each subdirectory that is a git repository with a `Package.swift`, its
/// manifests and the family packages they pin, read at `origin/main`, the commit a repin starts from.
public struct Family: Sendable {
    /// One repository of the family.
    public struct Member: Sendable, Equatable {
        public let name: String
        public let path: URL
        /// The `Package.swift` files `origin/main` tracks, relative to the repository, a test fixture's left out.
        public let manifests: [String]
        /// What those manifests pin, by package.
        public let pins: [FamilyManifest.Pin]
        /// The package identity SwiftPM compares.
        public var package: String { name.lowercased() }
        /// The packages it requires by revision.
        public var requires: Set<String> { Set(pins.map(\.package)).subtracting([package]) }
    }

    public let root: URL
    public let members: [Member]

    public init(root: URL, members: [Member]) {
        self.root = root
        self.members = members
    }

    /// The family under `root`, read with git at each repository's `origin/main`.
    public static func load(root: URL) throws -> Family {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var members: [Member] = []
        for name in names where !name.hasPrefix(".") {
            let path = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path),
                FileManager.default.fileExists(atPath: path.appendingPathComponent("Package.swift").path)
            else { continue }
            let listed = try Shell.output(
                ["git", "ls-tree", "-r", "--name-only", "origin/main"],
                directory: path,
                quiet: true
            )
            let manifests = listed.split(separator: "\n").map(String.init).filter(isManifest)
            var pins: [FamilyManifest.Pin] = []
            for manifest in manifests {
                let text = try Shell.output(["git", "show", "origin/main:\(manifest)"], directory: path, quiet: true)
                pins += FamilyManifest.pins(in: text)
            }
            members.append(Member(name: name, path: path, manifests: manifests, pins: pins))
        }
        return Family(root: root, members: members)
    }

    /// A manifest a repin rewrites: `Package.swift` anywhere but in tests and fixtures.
    static func isManifest(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.last == "Package.swift" && !parts.contains { $0 == "Tests" || $0 == "Fixtures" }
    }

    /// The member named `package`, in any case.
    public func member(_ package: String) -> Member? { members.first { $0.package == package.lowercased() } }

    /// The members by level: each level's only require members of the levels above it.
    public func levels() -> [[Member]] {
        let known = Set(members.map(\.package))
        var placed: Set<String> = []
        var remaining = members
        var levels: [[Member]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.requires.intersection(known).isSubset(of: placed) }
            // A cycle cannot be ordered: what is left goes last, as one level, rather than never.
            let level = ready.isEmpty ? remaining : ready
            levels.append(level)
            placed.formUnion(level.map(\.package))
            remaining.removeAll { member in level.contains(member) }
        }
        return levels
    }

    /// The members a change to `changed` forces a pin commit in, in the order they are repinned.
    public func dependents(of changed: Set<String>) -> [Member] {
        var moved = Set(changed.map { $0.lowercased() })
        var order: [Member] = []
        for member in levels().joined() where !moved.contains(member.package) {
            guard !member.requires.isDisjoint(with: moved) else { continue }
            order.append(member)
            moved.insert(member.package)
        }
        return order
    }
}
