public import Foundation

/// A release note with the fixed sections, as the g-cqd tools write them before a tag (analyzerkit roadmap 0030).
///
/// Every section must be present, in any order, and hold text or "none". A checksum written in Archives must be one of
/// the published ones. The Archives section is then rewritten with every archive and the SwiftPM checksum of the
/// artifact bundle.
public enum ReleaseNote {
    public static let sections = [
        "Archives", "Flags", "Exit codes", "Report", "Configuration", "Cache",
        "Findings that may appear", "Findings that may disappear", "Consumer steps"
    ]

    /// A published file and its SHA-256, as a `.sha256` file names them.
    public struct Asset: Sendable, Equatable {
        public var name: String
        public var digest: String

        public init(name: String, digest: String) {
            self.name = name
            self.digest = digest.lowercased()
        }
    }

    /// The note with its Archives section filled, or every problem found.
    public static func fill(_ text: String, assets: [Asset]) -> Result<String, Problems> {
        var title = ""
        var bodies: [String: [String]] = [:]
        var order: [String] = []
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## ") {
                let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                current = name
                if bodies[name] == nil { order.append(name) }
                bodies[name] = []
            } else if let name = current {
                bodies[name, default: []].append(line)
            } else {
                title += line + "\n"
            }
        }
        var problems = sections.filter { bodies[$0] == nil }.map { "missing section: \($0)" }
        for name in sections where name != "Archives" {
            guard let body = bodies[name] else { continue }
            if withoutComments(body.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("empty section: \(name) (write the change, or none)")
            }
        }
        if assets.isEmpty { problems.append("no published .sha256 file") }
        let published = Set(assets.map(\.digest))
        for digest in digests(in: (bodies["Archives"] ?? []).joined(separator: "\n")) where !published.contains(digest)
        {
            problems.append("Archives: \(digest) does not match a published .sha256")
        }
        guard problems.isEmpty else { return .failure(Problems(messages: problems)) }

        var archives = [""] + assets.map { "- `\($0.name)`: `\($0.digest)`" }
        for asset in assets where asset.name.hasSuffix(".artifactbundle.zip") {
            archives += ["", "SwiftPM checksum (`swift package compute-checksum`): `\(asset.digest)`"]
        }
        bodies["Archives"] = archives + [""]
        var out = title
        for name in order {
            let body = (bodies[name] ?? []).joined(separator: "\n")
            out += "## \(name)\n" + body.trimmingTrailingNewlines() + "\n\n"
        }
        return .success(out.trimmingTrailingNewlines() + "\n")
    }

    public struct Problems: Error, Equatable, CustomStringConvertible {
        public var messages: [String]
        public var description: String { messages.joined(separator: "\n") }
    }

    /// The assets of the `.sha256` files in `directory` (each `<digest>  <name>`), by file name.
    public static func assets(in directory: URL) throws -> [Asset] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".sha256") }.sorted()
        return try names.map { file in
            let words = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                .split(whereSeparator: \.isWhitespace)
            guard words.count >= 2 else { throw SwiftCIError("\(file): not '<digest>  <name>'") }
            var name = String(words[1])
            if name.hasPrefix("*") { name.removeFirst() }
            return Asset(name: name, digest: String(words[0]))
        }
    }

    static func withoutComments(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "-->") else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// Words (runs of letters, digits and `_`, as a regular expression's `\\w`) of exactly 64 hexadecimal digits.
    static func digests(in text: String) -> [String] {
        let isWord = { (character: Character) in character.isLetter || character.isNumber || character == "_" }
        return text.split(whereSeparator: { !isWord($0) })
            .filter { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }
            .map { $0.lowercased() }
    }
}

/// The `.artifactbundle` SwiftPM's `.binaryTarget(url:checksum:)` consumes, made from the release archives, so a
/// package can depend on a pinned build of a tool with no source build.
public enum ArtifactBundle {
    /// One archived binary: the tool, its version, and the target triple it runs on.
    public struct Variant: Sendable, Equatable {
        public var path: String
        public var triple: String

        public init(path: String, triple: String) {
            self.path = path
            self.triple = triple
        }
    }

    /// The triple of an archive name `<tool>-<version>-<platform>` (`macos-arm64`, `linux-x86_64`, ...).
    public static func triple(platform: String) -> String? {
        switch platform {
            case "macos-arm64": "arm64-apple-macosx"
            case "macos-x86_64": "x86_64-apple-macosx"
            case "linux-x86_64": "x86_64-unknown-linux-gnu"
            case "linux-aarch64": "aarch64-unknown-linux-gnu"
            default: nil
        }
    }

    /// `info.json` of a bundle of `tool` at `version`.
    public static func info(tool: String, version: String, variants: [Variant]) throws -> Data {
        struct Info: Encodable {
            let schemaVersion = "1.0"
            let artifacts: [String: Artifact]
            struct Artifact: Encodable {
                let type = "executable"
                let version: String
                let variants: [VariantInfo]
            }
            struct VariantInfo: Encodable {
                let path: String
                let supportedTriples: [String]
            }
        }
        let info = Info(artifacts: [
            tool: .init(
                version: version,
                variants: variants.map { .init(path: $0.path, supportedTriples: [$0.triple]) }
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(info)
    }

    /// Splits `<tool>-<version>-<os>-<arch>.tar.gz` into its version and platform; nil for another name.
    public static func parse(archive name: String, tool: String) -> (version: String, platform: String)? {
        guard name.hasPrefix(tool + "-"), name.hasSuffix(".tar.gz") else { return nil }
        let stem = name.dropFirst(tool.count + 1).dropLast(".tar.gz".count)
        let parts = stem.split(separator: "-")
        guard parts.count >= 3, let first = parts.first?.first, first.isNumber else { return nil }
        let platform = parts.suffix(2).joined(separator: "-")
        guard triple(platform: platform) != nil else { return nil }
        return (parts.dropLast(2).joined(separator: "-"), platform)
    }
}

extension String {
    func trimmingTrailingNewlines() -> String {
        var copy = self
        while copy.hasSuffix("\n") { copy.removeLast() }
        return copy
    }
}
