public import Foundation

/// Quality's swift-format check. One rule's verdict depends on the platform: `BeginDocumentationCommentWithOneLineSummary`
/// finds a comment's first sentence with NaturalLanguage on Apple platforms and with a period heuristic elsewhere,
/// which ends a sentence at "e.g." and drops inline code, so a summary macOS accepts fails on Linux. Such a rule is
/// checked where its reference implementation runs; elsewhere the configuration is the project's with it off.
public enum SwiftFormatLint {
    /// Rules whose result differs between a platform with NaturalLanguage and one without.
    public static let naturalLanguageRules = ["BeginDocumentationCommentWithOneLineSummary"]

    /// Whether swift-format, built for this platform like swift-ci, has NaturalLanguage.
    public static var hasNaturalLanguage: Bool {
        #if canImport(NaturalLanguage)
            true
        #else
            false
        #endif
    }

    public static func arguments(configuration: String, files: [String]) -> [String] {
        ["swift", "format", "lint", "--strict", "--parallel", "--configuration", configuration] + files
    }

    /// The configuration to lint with here: nil for the project's own, else its JSON with the rules that need
    /// NaturalLanguage turned off, when the platform has none and the project turns one on.
    public static func portableConfiguration(from data: Data, naturalLanguage: Bool) throws -> Data? {
        guard !naturalLanguage else { return nil }
        var enabled: [String] = []
        let adapted = try rewritingRules(of: data) { rules in
            enabled = naturalLanguageRules.filter { (rules[$0] as? Bool) == true }
            for rule in enabled { rules[rule] = false }
        }
        return enabled.isEmpty ? nil : adapted
    }

    /// A `.swift-format` with its `rules` edited by `edit`, every other setting as it was.
    static func rewritingRules(of data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftCIError(".swift-format is not a JSON object")
        }
        var rules = json["rules"] as? [String: Any] ?? [:]
        edit(&rules)
        json["rules"] = rules
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}
