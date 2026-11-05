import Foundation

/// A repository at one commit, copied into the project before the checks that need it: a conformance suite or a corpus
/// kept out of the repository (`{"id": "suites", "git": [{"git": URL, "commit": SHA, "into": PATH}], "before": [...]}`).
///
/// The commit is the integrity check: git names a commit by the hash of its content, so a fetch that yields any other
/// tree fails. Only that commit is fetched, without history; the copy has no `.git` and carries a stamp naming the
/// commit, so a later run with the same commit does nothing and a run with another replaces it.
public struct GitFixture: Codable, Sendable, Equatable {
    /// The repository, as an `https://` URL.
    public var git: String
    /// The full 40-character commit.
    public var commit: String
    /// Where the files go, relative to the root and inside it: `.build/fixtures/toml-test`.
    public var into: String

    public init(git: String, commit: String, into: String) {
        self.git = git
        self.commit = commit
        self.into = into
    }

    /// The file in the copy that names its commit.
    public static let stamp = ".swift-ci-commit"

    /// Why the fixture cannot be fetched, or nil.
    public func problem() -> String? {
        guard git.hasPrefix("https://"), git.count > "https://".count else { return "git must be an https:// URL" }
        guard commit.count == 40, commit.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return "commit must be a full 40-character lowercase commit hash"
        }
        let parts = into.split(separator: "/", omittingEmptySubsequences: false)
        guard !into.isEmpty, !into.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            return "into must be a relative path inside the root, without . or .. or empty components"
        }
        guard parts.first != ".git", parts.first != ".ci" else { return "into must not be inside .git or .ci" }
        return nil
    }

    /// The commands that fetch the commit into `directory`, which they create: no history, no other ref.
    public func fetchCommands(into directory: String) -> [[String]] {
        [
            ["git", "init", "-q", directory],
            ["git", "-C", directory, "fetch", "-q", "--depth", "1", git, commit],
            ["git", "-C", directory, "-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD"]
        ]
    }
}
