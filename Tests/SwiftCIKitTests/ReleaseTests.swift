import Foundation
import SwiftCIKit
import Testing

/// The fixtures are those of aemi's `.github/release-note-tests`, which held the Python lint this replaces.
struct ReleaseNoteTests {
    func fill(_ note: String) throws -> Result<String, ReleaseNote.Problems> {
        let text = try String(contentsOf: fixtures("release-notes/notes/\(note)"), encoding: .utf8)
        return ReleaseNote.fill(text, assets: try ReleaseNote.assets(in: fixtures("release-notes/assets")))
    }

    @Test func `a complete note gets every archive and the bundle's SwiftPM checksum`() throws {
        let filled = try fill("good.md").get()
        #expect(filled.contains("- `tool-1.2.0-macos-arm64.tar.gz`: `\(String(repeating: "a", count: 64))`"))
        #expect(filled.contains("- `tool-1.2.0-linux-x86_64.tar.gz`: `\(String(repeating: "b", count: 64))`"))
        #expect(
            filled.contains(
                "SwiftPM checksum (`swift package compute-checksum`): `\(String(repeating: "c", count: 64))`"
            )
        )
        #expect(filled.hasSuffix("\n") && !filled.hasSuffix("\n\n"))
        #expect(try fill("right-checksum.md").get().contains("## Archives"))
    }

    @Test(arguments: [
        ("freeform.md", "missing section: Archives"),
        ("empty-section.md", "empty section: Report"),
        ("missing-section.md", "missing section: Cache"),
        ("wrong-checksum.md", "does not match a published .sha256")
    ])
    func `an incomplete note is refused with what is wrong`(note: String, message: String) throws {
        guard case .failure(let problems) = try fill(note) else {
            Issue.record("\(note) passed")
            return
        }
        #expect(problems.messages.contains { $0.contains(message) }, "\(problems)")
    }

    @Test func `a note with no published archive is refused`() {
        guard case .failure(let problems) = ReleaseNote.fill("## Archives\n", assets: []) else {
            Issue.record("passed")
            return
        }
        #expect(problems.messages.contains("no published .sha256 file"))
    }

    @Test func `comments do not count as content, and only whole 64-digit words are checksums`() {
        let sections = ReleaseNote.sections.filter { $0 != "Archives" }.map { "## \($0)\nnone\n" }.joined()
        let note =
            "# v1\n## Archives\n"
            + sections.replacingOccurrences(of: "## Cache\nnone", with: "## Cache\n<!-- later -->")
        guard
            case .failure(let problems) = ReleaseNote.fill(
                note,
                assets: [.init(name: "a.tar.gz", digest: String(repeating: "d", count: 64))]
            )
        else {
            Issue.record("passed")
            return
        }
        #expect(problems.messages == ["empty section: Cache (write the change, or none)"])
        let words =
            "x\(String(repeating: "e", count: 64)) \(String(repeating: "f", count: 64)) \(String(repeating: "0", count: 65))"
        let filled = ReleaseNote.fill(
            "## Archives\n\(words)\n" + sections,
            assets: [.init(name: "a", digest: String(repeating: "1", count: 64))]
        )
        guard case .failure(let wrong) = filled else {
            Issue.record("passed")
            return
        }
        #expect(wrong.messages == ["Archives: \(String(repeating: "f", count: 64)) does not match a published .sha256"])
    }
}

struct ArtifactBundleTests {
    @Test(arguments: [
        ("tool-1.2.0-macos-arm64.tar.gz", "1.2.0", "macos-arm64"),
        ("tool-1.2.0-rc.1-linux-x86_64.tar.gz", "1.2.0-rc.1", "linux-x86_64")
    ])
    func `archive names give the version and platform`(name: String, version: String, platform: String) throws {
        let parsed = try #require(ArtifactBundle.parse(archive: name, tool: "tool"))
        #expect(parsed.version == version && parsed.platform == platform)
    }

    @Test func `other names are not archives of the tool`() {
        for name in [
            "tool-full-1.2.0-macos-arm64.tar.gz", "other-1.0-macos-arm64.tar.gz", "tool-1.2.0-windows-x86_64.tar.gz",
            "tool-1.2.0.zip"
        ] {
            #expect(ArtifactBundle.parse(archive: name, tool: "tool") == nil, "\(name)")
        }
    }

    @Test func `info.json names each variant's path and triple`() throws {
        let data = try ArtifactBundle.info(
            tool: "tool",
            version: "1.2.0",
            variants: [.init(path: "tool-1.2.0-macos-arm64/bin/tool", triple: "arm64-apple-macosx")]
        )
        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"artifacts":{"tool":{"type":"executable","variants":[{"path":"tool-1.2.0-macos-arm64\/bin\/tool","supportedTriples":["arm64-apple-macosx"]}],"version":"1.2.0"}},"schemaVersion":"1.0"}"#
        )
    }
}

/// The executor's tool installation against a local archive: the hash and the version are checked before a tool runs.
struct ToolInstallTests {
    func makeArchive(in sandbox: borrowing Sandbox, reporting version: String) throws -> (url: String, sha256: String) {
        let folder = sandbox.root.appendingPathComponent("t-1.0-\(ToolLock.Platform.current?.rawValue ?? "x")")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("t")
        try "#!/bin/sh\necho \(version)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Shell.run(["tar", "-czf", "t.tar.gz", folder.lastPathComponent], directory: sandbox.root)
        let archive = sandbox.root.appendingPathComponent("t.tar.gz")
        return (archive.absoluteString, try Shell.sha256(of: archive))
    }

    func tool(url: String, sha256: String) -> ToolLock.Tool {
        var archives: [String: ToolLock.Tool.Archive] = [:]
        for platform in ToolLock.Platform.allCases { archives[platform.rawValue] = .init(url: url, sha256: sha256) }
        return ToolLock.Tool(name: "t", version: "1.0", archives: archives, binary: "t-1.0-{platform}/t", arguments: [])
    }

    @Test(.enabled(if: ToolLock.Platform.current != nil))
    func `a tool with the pinned hash and version installs once, and runs`() throws {
        let sandbox = try Sandbox()
        let (url, sha256) = try makeArchive(in: sandbox, reporting: "1.0")
        var executor = Executor(root: sandbox.root, toolCache: sandbox.root.appendingPathComponent("cache"))
        let locked = tool(url: url, sha256: sha256)
        try executor.run([.install(locked), .tool(name: "t", title: "t", arguments: [])])
        try FileManager.default.removeItem(at: sandbox.root.appendingPathComponent("t.tar.gz"))
        try executor.run([.install(locked)])  // installed: no download
    }

    @Test(.enabled(if: ToolLock.Platform.current != nil))
    func `a wrong hash or a wrong version is refused, and nothing is installed`() throws {
        let sandbox = try Sandbox()
        let (url, sha256) = try makeArchive(in: sandbox, reporting: "2.0")
        let cache = sandbox.root.appendingPathComponent("cache")
        var executor = Executor(root: sandbox.root, toolCache: cache)
        #expect {
            try executor.run([.install(tool(url: url, sha256: String(repeating: "0", count: 64)))])
        } throws: { "\($0)".contains("not the pinned") }
        #expect {
            try executor.run([.install(tool(url: url, sha256: sha256))])
        } throws: { "\($0)".contains("reports '2.0', not 1.0") }
        #expect(
            !FileManager.default.fileExists(
                atPath: cache.appendingPathComponent("t-1.0-\(ToolLock.Platform.current!.rawValue)").path
            )
        )
        #expect(throws: SwiftCIError.self) { try executor.run([.tool(name: "t", title: "t", arguments: [])]) }
    }
}
