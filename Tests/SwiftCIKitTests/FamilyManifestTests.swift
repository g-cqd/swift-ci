import Foundation
import SwiftCIKit
import Testing

/// The family's pins read and rewritten as text (`swift-ci family`): only the revisions change.
struct FamilyManifestTests {
    static let old = String(repeating: "a", count: 40)
    static let new = String(repeating: "b", count: 40)
    static let manifest = """
        let package = Package(
            dependencies: [
                .package(url: "https://github.com/g-cqd/AemiJSON.git", revision: "\(old)"),
                // a comment
                .package(
                    url: "https://github.com/Aemi-Studio/aemi",
                    revision: "\(old)"
                ),
                .package(url: "https://github.com/apple/swift-collections.git", "1.7.1" ..< "1.8.0"),
                .package(url: "https://github.com/g-cqd/HTTP.git", branch: "main"),
            ]
        )
        """

    @Test func thePatternsCompile() { #expect(FamilyManifest.expressionsCompile) }

    @Test func pinsAreTheFamilysRevisionEdgesOnly() {
        let pins = FamilyManifest.pins(in: Self.manifest)
        #expect(pins.map(\.package) == ["aemijson", "aemi"])
        #expect(pins.map(\.owner) == ["g-cqd", "Aemi-Studio"])
        #expect(pins.allSatisfy { $0.revision == Self.old })
    }

    @Test func aRewriteChangesOnlyTheRevisionsAsked() {
        let rewritten = FamilyManifest.rewriting(Self.manifest, to: ["aemijson": Self.new])
        #expect(
            rewritten
                == Self.manifest.replacingOccurrences(
                    of: "AemiJSON.git\", revision: \"\(Self.old)",
                    with: "AemiJSON.git\", revision: \"\(Self.new)"
                )
        )
        #expect(FamilyManifest.pins(in: rewritten).map(\.revision) == [Self.new, Self.old])
        #expect(FamilyManifest.rewriting(Self.manifest, to: [:]) == Self.manifest)
    }

    @Test func aWorkflowsSwiftCICommitAndItsCommentMove() {
        let workflow =
            "    uses: g-cqd/swift-ci/.github/workflows/swift-ci.yml@\(Self.old) # swift-ci aaaaaaa\n      - uses: g-cqd/swift-ci@\(Self.old)\n"
        #expect(FamilyManifest.swiftCIRevisions(in: workflow) == [Self.old, Self.old])
        let rewritten = FamilyManifest.rewritingSwiftCI(workflow, to: Self.new)
        #expect(
            rewritten
                == "    uses: g-cqd/swift-ci/.github/workflows/swift-ci.yml@\(Self.new) # swift-ci bbbbbbb\n      - uses: g-cqd/swift-ci@\(Self.new)\n"
        )
    }
}
