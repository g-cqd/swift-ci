public import Foundation

/// Published security advisories against the versions a repository pins (`swift-ci advisories`, the `advisories`
/// check). Every `Package.resolved` the repository tracks is read, Xcode's included; each GitHub-hosted pin is looked up
/// in its own repository's published advisories and in GitHub's advisory database. Both are needed: a maintainer's
/// advisory reaches the database only once GitHub reviews it, and Dependabot alerts only on the database. A pin
/// without a version (a revision or a branch) cannot be compared, and is listed as such.
public enum Advisories {
    /// One pin of one `Package.resolved`.
    public struct Pin: Sendable, Equatable {
        public var identity: String
        public var location: String
        public var version: String?
        public var file: String
    }

    /// An advisory's range that holds a pinned version.
    public struct Finding: Sendable, Equatable, CustomStringConvertible {
        public var pin: Pin
        public var files: [String]
        public var id: String
        public var severity: String
        public var summary: String
        public var range: String
        public var patched: String?
        public var url: String

        public var description: String {
            let fixed = patched.map { ", fixed in \($0)" } ?? ", no fixed version"
            return "\(pin.identity) \(pin.version ?? "?") (\(files.joined(separator: ", "))): \(id) \(severity)"
                + " [\(range)\(fixed)]: \(summary) \(url)"
        }
    }

    /// What a check found.
    public struct Report: Sendable, Equatable {
        public var findings: [Finding] = []
        /// GitHub pins with a version, each looked up once.
        public var checked: [String] = []
        /// The packages pinned where none can be compared: by revision or branch, or not on GitHub; each once.
        public var unchecked: [String] = []
    }

    /// The pins of a `Package.resolved` (versions 1 to 3).
    public static func pins(resolved data: Data, file: String) throws -> [Pin] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftCIError("\(file): not a Package.resolved")
        }
        let list = (root["pins"] ?? (root["object"] as? [String: Any])?["pins"]) as? [[String: Any]] ?? []
        return list.compactMap { pin in
            guard let location = (pin["location"] ?? pin["repositoryURL"]) as? String else { return nil }
            let identity = (pin["identity"] ?? pin["package"]) as? String ?? location
            let state = pin["state"] as? [String: Any] ?? [:]
            return Pin(
                identity: identity.lowercased(),
                location: location,
                version: state["version"] as? String,
                file: file
            )
        }
    }

    /// `owner/name`, lowercased, for a GitHub location (HTTPS or SSH, with or without `.git`); nil elsewhere.
    public static func gitHubRepository(_ location: String) -> String? {
        var text = location.lowercased()
        for prefix in ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"]
        where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            if text.hasSuffix(".git") { text.removeLast(4) }
            while text.hasSuffix("/") { text.removeLast() }
            let parts = text.split(separator: "/")
            return parts.count == 2 ? text : nil
        }
        return nil
    }

    /// Whether `range` (as advisories write them: `>= 4.0.0, <= 5.1.1`, `<=5.1.1`, `4.0.0 - 4.3.0`, `= 1.2.3`) holds
    /// `version`; nil when either cannot be read.
    public static func contains(_ range: String, _ version: String) -> Bool? {
        guard let pinned = SemanticVersion(version) else { return nil }
        var holds = true
        for part in range.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            if let dash = part.range(of: " - ") {
                guard let low = SemanticVersion(String(part[..<dash.lowerBound])),
                    let high = SemanticVersion(String(part[dash.upperBound...]))
                else { return nil }
                holds = holds && low <= pinned && pinned <= high
                continue
            }
            let operators = [">=", "<=", "==", ">", "<", "="]
            let symbol = operators.first { part.hasPrefix($0) } ?? ""
            guard let bound = SemanticVersion(String(part.dropFirst(symbol.count))) else { return nil }
            switch symbol {
                case ">=": holds = holds && pinned >= bound
                case "<=": holds = holds && pinned <= bound
                case ">": holds = holds && pinned > bound
                case "<": holds = holds && pinned < bound
                default: holds = holds && pinned == bound
            }
        }
        return holds
    }

    /// Looks every pin of `files` up (paths relative to `top`) through `source`.
    public static func check(top: URL, files: [String], source: some AdvisorySource) throws -> Report {
        var byRepository: [String: (pin: Pin, files: [String])] = [:]
        var report = Report()
        for file in files {
            let data = try Data(contentsOf: top.appendingPathComponent(file))
            for pin in try pins(resolved: data, file: file) {
                guard let repository = gitHubRepository(pin.location), let version = pin.version else {
                    report.unchecked.append(pin.identity)
                    continue
                }
                let key = "\(repository)@\(version)"
                byRepository[key, default: (pin, [])].files.append(file)
            }
        }
        var cache: [String: [Advisory]] = [:]
        for key in byRepository.keys.sorted() {
            guard let entry = byRepository[key], let version = entry.pin.version,
                let repository = gitHubRepository(entry.pin.location)
            else { continue }
            report.checked.append("\(entry.pin.identity) \(version)")
            if cache[repository] == nil {
                cache[repository] = try source.advisories(repository: repository, identity: entry.pin.identity)
            }
            for advisory in cache[repository] ?? [] {
                for range in advisory.ranges where contains(range.range, version) != false {
                    report.findings.append(
                        Finding(
                            pin: entry.pin,
                            files: entry.files,
                            id: advisory.id,
                            severity: advisory.severity,
                            summary: advisory.summary,
                            range: range.range,
                            patched: range.patched,
                            url: advisory.url
                        )
                    )
                    break
                }
            }
        }
        report.unchecked = Array(Set(report.unchecked)).sorted()
        return report
    }
}

/// One advisory, from either source, with the ranges that concern the package looked up.
public struct Advisory: Sendable, Equatable {
    public struct Range: Sendable, Equatable {
        public var range: String
        public var patched: String?
    }

    public var id: String
    public var severity: String
    public var summary: String
    public var url: String
    public var ranges: [Range]
}

/// Where advisories come from: GitHub (``GitHubAdvisories``), or a test's table.
public protocol AdvisorySource {
    /// The advisories, not withdrawn, of the package at `repository` (`owner/name`) whose identity is `identity`.
    func advisories(repository: String, identity: String) throws -> [Advisory]
}

/// A version as advisories and SwiftPM write them: `1.2.3`, `v1.2`, `1.2.3-beta.1`; a pre-release is below its release.
struct SemanticVersion: Comparable, Sendable {
    var numbers: [Int]
    var prerelease: [String]

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        let parts = text.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 } + Array(repeating: 0, count: max(0, 3 - numbers.count))
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
            case (true, _): return false
            case (false, true): return true
            case (false, false):
                for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
                    if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
                    return left < right
                }
                return lhs.prerelease.count < rhs.prerelease.count
        }
    }
}
