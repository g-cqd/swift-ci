import Foundation
import SwiftCIKit
import Testing

struct ProjectTests {
    @Test func `a package, its formatters by configuration file, and what the analyzers read`() throws {
        let sandbox = try Sandbox([
            "Package.swift": "", ".swift-format": "{}", ".swiftlint.yml": "", "Sources/A/a.swift": "", "Tests/": ""
        ])
        let project = try Project.detect(root: sandbox.root, configuration: Configuration())
        #expect(project.kind == .package)
        #expect(project.linux)
        #expect(project.formatters == [.swiftFormat, .swiftLint])
        #expect(project.corpus == ["Sources", "Tests"])
    }

    @Test func `a workspace wins over a project, and an Xcode project needs schemes`() throws {
        let sandbox = try Sandbox(["App.xcodeproj/": "", "App.xcworkspace/": "", ".swiftformat": ""])
        #expect(throws: SwiftCIError("an Xcode project needs project.schemes")) {
            try Project.detect(root: sandbox.root, configuration: Configuration())
        }
        let project = try Project.detect(
            root: sandbox.root,
            configuration: try configuration(#"{"project": {"schemes": ["App"]}}"#)
        )
        #expect(project.kind == .xcodeWorkspace)
        #expect(project.xcode == "App.xcworkspace")
        #expect(!project.linux)
        #expect(project.formatters == [.nickSwiftFormat])
        #expect(project.corpus == ["."])
    }

    @Test func `several projects must be named, and a named one must exist`() throws {
        let sandbox = try Sandbox(["A.xcodeproj/": "", "B.xcodeproj/": ""])
        let schemes = try configuration(#"{"project": {"schemes": ["A"]}}"#)
        #expect {
            try Project.detect(root: sandbox.root, configuration: schemes)
        } throws: { "\($0)".contains("several Xcode projects") }
        let named = try configuration(#"{"project": {"schemes": ["B"], "xcode": "B.xcodeproj"}}"#)
        #expect(try Project.detect(root: sandbox.root, configuration: named).xcode == "B.xcodeproj")
        let missing = try configuration(#"{"project": {"schemes": ["C"], "xcode": "C.xcodeproj"}}"#)
        #expect(throws: SwiftCIError("project.xcode: no C.xcodeproj")) {
            try Project.detect(root: sandbox.root, configuration: missing)
        }
    }

    @Test func `a package beside an Xcode project is the package, unless told otherwise`() throws {
        let sandbox = try Sandbox(["Package.swift": "", "Demo.xcodeproj/": ""])
        #expect(try Project.detect(root: sandbox.root, configuration: Configuration()).kind == .package)
        let xcode = try configuration(#"{"project": {"kind": "xcode", "schemes": ["Demo"]}}"#)
        #expect(try Project.detect(root: sandbox.root, configuration: xcode).kind == .xcodeProject)
    }

    @Test func `nothing to build is an error, and explicit settings win`() throws {
        let empty = try Sandbox(["README.md": ""])
        #expect(throws: SwiftCIError.self) { try Project.detect(root: empty.root, configuration: Configuration()) }
        let sandbox = try Sandbox(["Package.swift": "", ".swift-format": "", ".swiftlint.yml": ""])
        let settings = try configuration(
            #"{"project": {"linux": false}, "quality": {"formatters": ["swiftlint"], "paths": ["Lib"]}}"#
        )
        let project = try Project.detect(root: sandbox.root, configuration: settings)
        #expect(!project.linux)
        #expect(project.formatters == [.swiftLint])
        #expect(project.corpus == ["Lib"])
    }
}
