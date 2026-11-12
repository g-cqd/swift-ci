import Foundation

/// The family's pins in a manifest or a workflow (`swift-ci family`): the g-cqd and Aemi-Studio packages a `Package.swift` requires
/// by exact revision, and the swift-ci commit a workflow uses. Read and rewritten as text, so a repin changes only the revisions.
public enum FamilyManifest {
    /// One package a manifest pins: its repository's name as written, the owner, and the revision.
    public struct Pin: Equatable, Sendable {
        public let owner: String
        public let repository: String
        public let revision: String
        /// The repository's name in the case SwiftPM compares identities in.
        public var package: String { repository.lowercased() }
    }

    // Constant patterns, built once; `expressionsCompile` says they did (a test holds it).
    private static let edge = try? NSRegularExpression(
        pattern:
            #"\.package\(\s*url:\s*"https://github\.com/(g-cqd|Aemi-Studio)/([^/"]+?)(?:\.git)?"\s*,\s*revision:\s*"([0-9a-f]{40})""#
    )
    private static let workflowUse = try? NSRegularExpression(
        pattern: #"(g-cqd/swift-ci(?:/[^@\s"']*)?@)([0-9a-f]{40})((?:\s*#\s*swift-ci\s+)([0-9a-f]{7,40}))?"#
    )

    /// The family packages `text`, a `Package.swift`, requires by exact revision, in order.
    public static func pins(in text: String) -> [Pin] {
        matches(edge, in: text)
            .map { match in
                Pin(owner: group(match, 1, text), repository: group(match, 2, text), revision: group(match, 3, text))
            }
    }

    /// `text` with each pin of a package in `revisions` (by ``Pin/package``) moved to its new revision; nothing else changes.
    public static func rewriting(_ text: String, to revisions: [String: String]) -> String {
        replacing(edge, in: text) { match in
            guard let revision = revisions[group(match, 2, text).lowercased()],
                let range = Range(match.range(at: 3), in: text)
            else { return [] }
            return [(range, revision)]
        }
    }

    /// The swift-ci commits `text`, a workflow, uses.
    public static func swiftCIRevisions(in text: String) -> [String] {
        matches(workflowUse, in: text).map { group($0, 2, text) }
    }

    /// `text`, a workflow, using swift-ci at `revision`, with the short commit a comment after it names updated too.
    public static func rewritingSwiftCI(_ text: String, to revision: String) -> String {
        replacing(workflowUse, in: text) { match in
            var changes: [(Range<String.Index>, String)] = []
            if let range = Range(match.range(at: 2), in: text) { changes.append((range, revision)) }
            if let range = Range(match.range(at: 4), in: text) { changes.append((range, String(revision.prefix(7)))) }
            return changes
        }
    }

    /// Whether both patterns compiled.
    public static var expressionsCompile: Bool { edge != nil && workflowUse != nil }

    private static func matches(_ expression: NSRegularExpression?, in text: String) -> [NSTextCheckingResult] {
        expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }

    /// `text` with the replacements `change` gives for each match, applied from the end so earlier ranges stay valid.
    private static func replacing(
        _ expression: NSRegularExpression?,
        in text: String,
        _ change: (NSTextCheckingResult) -> [(Range<String.Index>, String)]
    ) -> String {
        var result = text
        let changes = matches(expression, in: text).flatMap(change).sorted { $0.0.lowerBound > $1.0.lowerBound }
        for (range, replacement) in changes { result.replaceSubrange(range, with: replacement) }
        return result
    }
}
