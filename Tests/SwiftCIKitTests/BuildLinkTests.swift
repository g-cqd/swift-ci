import Foundation
import SwiftCIKit
import Testing

struct BuildLinkTests {
    @Test func `SwiftPM commands name the package whose .build they write, unless they bring a scratch path`() {
        #expect(BuildLink.packageDirectory(of: ["swift", "build", "--build-tests"]) == ".")
        #expect(BuildLink.packageDirectory(of: ["swift", "test", "--package-path", "Core"]) == "Core")
        #expect(BuildLink.packageDirectory(of: ["swift", "test", "--package-path=Core"]) == "Core")
        #expect(BuildLink.packageDirectory(of: ["swift", "build", "--scratch-path", "/tmp/s"]) == nil)
        #expect(BuildLink.packageDirectory(of: ["swift", "format", "lint"]) == nil)
        #expect(BuildLink.packageDirectory(of: ["xcodebuild", "test"]) == nil)
    }

    @Test func `a dangling .build link gets its target back, and anything else is left alone`() throws {
        let sandbox = try Sandbox(["Package.swift": "", "Linked/Package.swift": "", "Plain/.build/x": ""])
        let cache = sandbox.root.appendingPathComponent("cache/deep/p.build")
        try FileManager.default.createSymbolicLink(
            atPath: sandbox.root.appendingPathComponent(".build").path,
            withDestinationPath: cache.path
        )
        let note = try #require(try BuildLink.repair(packageDirectory: sandbox.root))
        #expect(note.contains("did not exist; created it"))
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(try BuildLink.repair(packageDirectory: sandbox.root) == nil)
        // A relative link resolves against the package directory.
        try FileManager.default.createSymbolicLink(
            atPath: sandbox.root.appendingPathComponent("Linked/.build").path,
            withDestinationPath: "../cache/linked"
        )
        #expect(try BuildLink.repair(packageDirectory: sandbox.root.appendingPathComponent("Linked")) != nil)
        #expect(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("cache/linked").path))
        #expect(try BuildLink.repair(packageDirectory: sandbox.root.appendingPathComponent("Plain")) == nil)
        #expect(try BuildLink.repair(packageDirectory: sandbox.root.appendingPathComponent("Missing")) == nil)
    }
}
