import Foundation

extension Executor {
    /// Fetches each fixture unless its copy already holds its commit (``GitFixture``).
    func fetch(_ fixtures: [GitFixture]) throws {
        for fixture in fixtures {
            try fetch(fixture)
        }
    }

    func fetch(_ fixture: GitFixture) throws {
        let target = root.appendingPathComponent(fixture.into)
        let stamp = target.appendingPathComponent(GitFixture.stamp)
        if let held = try? String(contentsOf: stamp, encoding: .utf8),
            held.trimmingCharacters(in: .whitespacesAndNewlines) == fixture.commit
        {
            return print("\(fixture.into): \(fixture.git) at \(fixture.commit.prefix(12)), already there")
        }
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Beside the target, so the final move stays on one volume and an interrupted fetch never looks complete.
        let work = parent.appendingPathComponent(".\(target.lastPathComponent)-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: work) }
        print("\(fixture.into): fetching \(fixture.git) at \(fixture.commit.prefix(12))")
        fflush(nil)
        for command in fixture.fetchCommands(into: work.path) {
            try Shell.run(command, directory: root)
        }
        let head = try Shell.output(["git", "-C", work.path, "rev-parse", "HEAD"], directory: root, quiet: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == fixture.commit else {
            throw SwiftCIError("\(fixture.into): \(fixture.git) gave commit \(head), not the pinned \(fixture.commit)")
        }
        try FileManager.default.removeItem(at: work.appendingPathComponent(".git"))
        try (fixture.commit + "\n")
            .write(to: work.appendingPathComponent(GitFixture.stamp), atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: work, to: target)
    }
}
