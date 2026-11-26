import Foundation
import SwiftCIKit
import Testing

struct FreeformReleaseNoteTests {
    private let assets = [
        ReleaseNote.Asset(name: "tool-1.0.0-macos-arm64.tar.gz", digest: String(repeating: "a", count: 64))
    ]

    /// A freeform note ending with an empty `## Archives` heading gets it filled in place, not a second section.
    @Test func `an empty trailing Archives section is filled in place`() throws {
        let note = "# tool 1.0.0\n\nNotes.\n\n## Archives\n"
        let filled = try ReleaseNote.fill(note, assets: assets, style: .freeform).get()
        #expect(filled.components(separatedBy: "## Archives").count == 2, "\(filled)")
        #expect(filled.contains("- `tool-1.0.0-macos-arm64.tar.gz`: `\(String(repeating: "a", count: 64))`"))
        #expect(filled.hasPrefix("# tool 1.0.0\n\nNotes.\n\n## Archives\n"))
    }

    @Test func `an Archives section followed by another section keeps that section`() throws {
        let note = "# tool\n\n## Archives\n\n## Thanks\n\nEveryone.\n"
        let filled = try ReleaseNote.fill(note, assets: assets, style: .freeform).get()
        #expect(filled.components(separatedBy: "## Archives").count == 2)
        #expect(filled.hasSuffix("## Thanks\n\nEveryone.\n"))
    }
}
