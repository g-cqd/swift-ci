import Foundation
import Testing

@testable import SwiftCIKit

@Suite("CycloneDX SBOM generation")
struct SBOMTests {
    @Test func generatesCycloneDX15FromPackageResolved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swift-ci-sbom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = """
            {
              "pins" : [
                {
                  "identity" : "aemijson",
                  "kind" : "remoteSourceControl",
                  "location" : "https://github.com/g-cqd/AemiJSON.git",
                  "state" : {
                    "revision" : "fdcf306b1ffbbd29161df787ae2ea97e56718d2c"
                  }
                },
                {
                  "identity" : "swift-argument-parser",
                  "kind" : "remoteSourceControl",
                  "location" : "https://github.com/apple/swift-argument-parser.git",
                  "state" : {
                    "revision" : "abc",
                    "version" : "1.5.0"
                  }
                }
              ],
              "version" : 2
            }
            """
        let resolvedURL = dir.appendingPathComponent("Package.resolved")
        try resolved.write(to: resolvedURL, atomically: true, encoding: .utf8)

        let data = try SBOM.generate(name: "ask", version: "0.1.0-alpha.1", packageResolved: resolvedURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["bomFormat"] as? String == "CycloneDX")
        #expect(json["specVersion"] as? String == "1.5")

        let components = try #require(json["components"] as? [[String: Any]])
        #expect(components.count == 2)
        #expect(components[0]["name"] as? String == "aemijson")
        #expect(
            components[0]["purl"] as? String
                == "pkg:swift/github.com/g-cqd/AemiJSON@fdcf306b1ffbbd29161df787ae2ea97e56718d2c"
        )
        #expect(components[1]["name"] as? String == "swift-argument-parser")
        #expect(components[1]["purl"] as? String == "pkg:swift/github.com/apple/swift-argument-parser@1.5.0")
    }

    @Test func handlesMissingPackageResolvedGracefully() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "missing-\(UUID().uuidString).resolved"
        )
        let data = try SBOM.generate(name: "tool", version: "1.0.0", packageResolved: missing)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let components = try #require(json["components"] as? [[String: Any]])
        #expect(components.isEmpty)
    }
}
