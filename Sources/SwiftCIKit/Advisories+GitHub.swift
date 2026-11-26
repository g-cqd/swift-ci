public import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Advisories from GitHub's REST API: the package's repository's published advisories, and the reviewed advisories of
/// GitHub's database for the Swift ecosystem (by `github.com/owner/name`, and by the bare name some entries use). A
/// token (`GITHUB_TOKEN`, `GH_TOKEN`, else `gh auth token`) raises the rate limit from 60 requests an hour; none of the
/// requests needs a permission. A repository that is gone or private has no advisories to read; any other failure stops
/// the check, which never passes on what it could not read.
public struct GitHubAdvisories: AdvisorySource {
    public var token: String?
    var get: @Sendable (URLRequest) throws -> (status: Int, data: Data)

    public init(token: String? = GitHubAdvisories.environmentToken()) {
        self.token = token
        get = HTTP.send
    }

    init(token: String?, get: @escaping @Sendable (URLRequest) throws -> (status: Int, data: Data)) {
        self.token = token
        self.get = get
    }

    public static func environmentToken() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"], !token.isEmpty { return token }
        let token = try? Shell.output(["gh", "auth", "token"], quiet: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    public func advisories(repository: String, identity: String) throws -> [Advisory] {
        let name = String(repository.split(separator: "/").last ?? "")
        let names: Set<String> = ["github.com/\(repository)", repository, name, identity]
        var found: [String: Advisory] = [:]
        let own = try list("repos/\(repository)/security-advisories?state=published&per_page=100")
        for object in own { if let advisory = Self.advisory(object, names: nil) { found[advisory.id] = advisory } }
        for affects in ["github.com/\(repository)", name] {
            let query = affects.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? affects
            for object in try list("advisories?ecosystem=swift&affects=\(query)&per_page=100") {
                if let advisory = Self.advisory(object, names: names), found[advisory.id] == nil {
                    found[advisory.id] = advisory
                }
            }
        }
        return found.values.sorted { $0.id < $1.id }
    }

    /// An advisory with the ranges of the packages in `names` (every range when nil: the repository's own advisory);
    /// nil when it is withdrawn or concerns none of them.
    static func advisory(_ object: [String: Any], names: Set<String>?) -> Advisory? {
        guard let id = object["ghsa_id"] as? String, object["withdrawn_at"] as? String == nil else { return nil }
        let vulnerabilities = object["vulnerabilities"] as? [[String: Any]] ?? []
        let ranges: [Advisory.Range] = vulnerabilities.compactMap { vulnerability in
            let package = vulnerability["package"] as? [String: Any]
            if let names {
                guard let name = (package?["name"] as? String)?.lowercased(), names.contains(name) else { return nil }
            }
            guard let range = vulnerability["vulnerable_version_range"] as? String, !range.isEmpty else { return nil }
            let first = vulnerability["first_patched_version"]
            let patched =
                vulnerability["patched_versions"] as? String ?? first as? String
                ?? (first as? [String: Any])?["identifier"] as? String
            return Advisory.Range(range: range, patched: patched?.isEmpty == false ? patched : nil)
        }
        guard !ranges.isEmpty else { return nil }
        return Advisory(
            id: id,
            severity: object["severity"] as? String ?? "unknown",
            summary: object["summary"] as? String ?? "",
            url: object["html_url"] as? String ?? "https://github.com/advisories/\(id)",
            ranges: ranges
        )
    }

    /// The objects at `path` of the REST API; none for a missing or private repository (404).
    func list(_ path: String) throws -> [[String: Any]] {
        guard let url = URL(string: "https://api.github.com/" + path) else {
            throw SwiftCIError("bad API path \(path)")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("swift-ci", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var failure = ""
        for attempt in 1 ... 3 {
            do {
                let (status, data) = try get(request)
                if status == 404 { return [] }
                guard status == 200 else {
                    failure = "HTTP \(status)"
                    if status == 403 || status == 429 || status >= 500, attempt < 3 {
                        Thread.sleep(forTimeInterval: Double(attempt * 2))
                        continue
                    }
                    break
                }
                guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw SwiftCIError("\(path): not a list")
                }
                return objects
            } catch let error as SwiftCIError {
                throw error
            } catch {
                failure = error.localizedDescription
                if attempt < 3 { Thread.sleep(forTimeInterval: Double(attempt * 2)) }
            }
        }
        throw SwiftCIError(
            "advisories: \(path) failed: \(failure)\(token == nil ? " (no token: set GITHUB_TOKEN)" : "")"
        )
    }
}
