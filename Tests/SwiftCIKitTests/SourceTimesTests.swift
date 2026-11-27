import Foundation
import Testing

@testable import SwiftCIKit

/// A checkout gives every file a new time; the times of the cached build come back to the files whose content is the same.
struct SourceTimesTests {
    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-times-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["git", "init", "-q"], ["git", "config", "user.email", "t@t"], ["git", "config", "user.name", "t"]
        ] {
            _ = try Shell.output(arguments, directory: root, quiet: true)
        }
        try Data("a".utf8).write(to: root.appendingPathComponent("same.swift"))
        try Data("b".utf8).write(to: root.appendingPathComponent("changed.swift"))
        _ = try Shell.output(["git", "add", "."], directory: root, quiet: true)
        _ = try Shell.output(["git", "commit", "-q", "-m", "x"], directory: root, quiet: true)
        return root
    }

    private func time(_ root: URL, _ name: String) throws -> Double {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
        return try #require(attributes[.modificationDate] as? Date).timeIntervalSince1970
    }

    @Test func `an unchanged file gets its kept time back; a changed one keeps its new time`() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_000_000)
        for name in ["same.swift", "changed.swift"] {
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: root.appendingPathComponent(name).path
            )
        }
        SourceTimes.save(root: root)
        // The next checkout: new times everywhere, and one file's content changed.
        let now = Date()
        for name in ["same.swift", "changed.swift"] {
            try FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: root.appendingPathComponent(name).path
            )
        }
        try Data("c".utf8).write(to: root.appendingPathComponent("changed.swift"))
        _ = try Shell.output(["git", "add", "."], directory: root, quiet: true)
        _ = try Shell.output(["git", "commit", "-q", "-m", "y"], directory: root, quiet: true)
        #expect(SourceTimes.restore(root: root) == 1)
        #expect(try time(root, "same.swift") == old.timeIntervalSince1970)
        #expect(try time(root, "changed.swift") > old.timeIntervalSince1970)
    }

    @Test func `no kept times restores nothing; lines that are not times are left out`() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SourceTimes.restore(root: root) == 0)
        #expect(
            SourceTimes.parse("abc\t12.5\tSources/a.swift\nnonsense\n") == [
                SourceTimes.Entry(path: "Sources/a.swift", object: "abc", time: 12.5)
            ]
        )
    }
}
