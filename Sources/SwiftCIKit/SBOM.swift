public import Foundation

/// Generates a minimal CycloneDX 1.5 JSON SBOM from a Swift package's `Package.resolved` (SLSA / CRA R-SC-3, T-ECO-1).
/// Keeps zero external dependencies so every `swift-ci` release publishes a verifiable dependency inventory alongside
/// its archives and SLSA build provenance attestations.
public enum SBOM {
    struct ResolvedV2: Decodable {
        struct Pin: Decodable {
            struct State: Decodable {
                let revision: String?
                let version: String?
                let branch: String?
            }
            let identity: String
            let kind: String?
            let location: String
            let state: State
        }
        let pins: [Pin]
        let version: Int
    }

    struct Document: Encodable {
        struct Metadata: Encodable {
            struct Component: Encodable {
                let type = "application"
                let name: String
                let version: String
            }
            let component: Component
        }
        struct Component: Encodable {
            struct ExternalRef: Encodable {
                let type = "vcs"
                let url: String
            }
            let type = "library"
            let name: String
            let version: String
            let purl: String
            let externalReferences: [ExternalRef]
        }
        let bomFormat = "CycloneDX"
        let specVersion = "1.5"
        let version = 1
        let metadata: Metadata
        let components: [Component]
    }

    /// Generates CycloneDX 1.5 JSON data for `name` at `version` from `packageResolved` (if present).
    public static func generate(
        name: String,
        version: String,
        packageResolved: URL
    ) throws -> Data {
        var components: [Document.Component] = []
        if FileManager.default.fileExists(atPath: packageResolved.path) {
            let raw = try Data(contentsOf: packageResolved)
            let resolved = try JSONDecoder().decode(ResolvedV2.self, from: raw)
            components = resolved.pins
                .sorted { $0.identity < $1.identity }
                .map { pin in
                    let ver = pin.state.version ?? pin.state.revision ?? pin.state.branch ?? "unknown"
                    let purl = Self.purl(location: pin.location, identity: pin.identity, version: ver)
                    return Document.Component(
                        name: pin.identity,
                        version: ver,
                        purl: purl,
                        externalReferences: [.init(url: pin.location)]
                    )
                }
        }
        let doc = Document(
            metadata: .init(component: .init(name: name, version: version)),
            components: components
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(doc)
        data.append(0x0A)
        return data
    }

    static func purl(location: String, identity: String, version: String) -> String {
        if let url = URL(string: location), let host = url.host?.lowercased(), host == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 {
                let owner = parts[0]
                let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
                return "pkg:swift/github.com/\(owner)/\(repo)@\(version)"
            }
        }
        return "pkg:swift/\(identity)@\(version)"
    }
}
