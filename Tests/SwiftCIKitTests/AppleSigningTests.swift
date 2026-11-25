import Foundation
import Testing

@testable import SwiftCIKit

@Suite("AppleSigning")
struct AppleSigningTests {
    @Test func `codesign arguments use timestamp for Developer ID and none for ad hoc`() {
        let devID = AppleSigning.Credentials(
            identity: "Developer ID Application",
            keychain: "/tmp/release.keychain-db"
        )
        let args = AppleSigning.codesignArguments(
            binaryPath: "/tmp/dist/ask",
            executableName: "ask",
            options: AppleSigning.Options(sign: true, identifier: "ask", hardenedRuntime: true),
            credentials: devID
        )
        #expect(
            args == [
                "codesign", "--force", "--sign", "Developer ID Application",
                "--identifier", "ask",
                "--keychain", "/tmp/release.keychain-db",
                "--options", "runtime",
                "--timestamp",
                "/tmp/dist/ask"
            ]
        )

        let adHoc = AppleSigning.Credentials(identity: "-")
        let adHocArgs = AppleSigning.codesignArguments(
            binaryPath: "/tmp/dist/ask",
            executableName: "ask",
            options: AppleSigning.Options(sign: true, identifier: nil, hardenedRuntime: false),
            credentials: adHoc
        )
        #expect(
            adHocArgs == [
                "codesign", "--force", "--sign", "-",
                "--identifier", "ask",
                "--timestamp=none",
                "/tmp/dist/ask"
            ]
        )
    }

    @Test func `notary arguments prefer API key credentials and fall back to keychain profile`() throws {
        let apiKey = AppleSigning.Credentials(
            identity: "Developer ID Application",
            notaryKeyPath: "/tmp/notary.p8",
            notaryKeyID: "KEY123",
            notaryIssuer: "ISSUER456"
        )
        #expect(apiKey.hasNotaryCredentials)
        #expect(
            try AppleSigning.notaryArguments(zipPath: "/tmp/ask.zip", credentials: apiKey) == [
                "xcrun", "notarytool", "submit", "/tmp/ask.zip", "--wait",
                "--key", "/tmp/notary.p8", "--key-id", "KEY123", "--issuer", "ISSUER456"
            ]
        )

        let profile = AppleSigning.Credentials(identity: "Developer ID Application", notaryProfile: "ask-notary")
        #expect(profile.hasNotaryCredentials)
        #expect(
            try AppleSigning.notaryArguments(zipPath: "/tmp/ask.zip", credentials: profile) == [
                "xcrun", "notarytool", "submit", "/tmp/ask.zip", "--wait",
                "--keychain-profile", "ask-notary"
            ]
        )

        let none = AppleSigning.Credentials(identity: "Developer ID Application")
        #expect(!none.hasNotaryCredentials)
        #expect(throws: SwiftCIError.self) {
            _ = try AppleSigning.notaryArguments(zipPath: "/tmp/ask.zip", credentials: none)
        }
    }

    @Test func `credentials decode from environment and ignore empty values`() {
        #expect(AppleSigning.Credentials.fromEnvironment([:]) == nil)
        #expect(AppleSigning.Credentials.fromEnvironment(["SWIFT_CI_SIGN_IDENTITY": ""]) == nil)

        let decoded = AppleSigning.Credentials.fromEnvironment([
            "SWIFT_CI_SIGN_IDENTITY": "Developer ID Application",
            "SWIFT_CI_SIGN_KEYCHAIN": "/tmp/k.keychain-db",
            "SWIFT_CI_NOTARY_KEY_PATH": "/tmp/n.p8",
            "SWIFT_CI_NOTARY_KEY_ID": "ABC",
            "SWIFT_CI_NOTARY_ISSUER": "DEF",
            "SWIFT_CI_NOTARY_PROFILE": ""
        ])
        #expect(
            decoded
                == AppleSigning.Credentials(
                    identity: "Developer ID Application",
                    keychain: "/tmp/k.keychain-db",
                    notaryKeyPath: "/tmp/n.p8",
                    notaryKeyID: "ABC",
                    notaryIssuer: "DEF",
                    notaryProfile: nil
                )
        )
    }

    @Test func `configuration decodes release appleSigning and freeform noteStyle`() throws {
        let json = """
            {
              "release": {
                "executables": ["ask"],
                "notes": "docs/releases/{tag}.md",
                "noteStyle": "freeform",
                "appleSigning": {
                  "sign": true,
                  "identifier": "ask",
                  "hardenedRuntime": true,
                  "notarize": true,
                  "requireOnTag": true
                }
              }
            }
            """
        let config = try configuration(json)
        #expect(config.release?.executables == ["ask"])
        #expect(config.release?.notes == "docs/releases/{tag}.md")
        #expect(config.release?.noteStyle == .freeform)
        #expect(
            config.release?.appleSigning
                == AppleSigning.Options(
                    sign: true,
                    identifier: "ask",
                    hardenedRuntime: true,
                    notarize: true,
                    requireOnTag: true
                )
        )
    }

    @Test func `freeform release notes append Archives table or replace existing section and verify digests`() throws {
        let digest = String(repeating: "a", count: 64)
        let assets = [ReleaseNote.Asset(name: "ask-0.1.0-alpha.1-macos-arm64.tar.gz", digest: digest)]

        let plain = "# ask 0.1.0-alpha.1\n\nFirst signed alpha.\n"
        let filled = try ReleaseNote.fill(plain, assets: assets, style: .freeform).get()
        #expect(filled.contains("First signed alpha."))
        #expect(filled.contains("## Archives\n\n- `ask-0.1.0-alpha.1-macos-arm64.tar.gz`: `\(digest)`"))

        let withPlaceholder = "# ask 0.1.0-alpha.1\n\nNotes.\n\n## Archives\n\n<!-- filled -->\n"
        let replaced = try ReleaseNote.fill(withPlaceholder, assets: assets, style: .freeform).get()
        #expect(replaced.contains("## Archives\n\n- `ask-0.1.0-alpha.1-macos-arm64.tar.gz`: `\(digest)`"))
        #expect(!replaced.contains("<!-- filled -->"))

        let bogus = "# ask\n\n\(String(repeating: "b", count: 64))\n"
        switch ReleaseNote.fill(bogus, assets: assets, style: .freeform) {
            case .success: Issue.record("expected mismatched digest failure")
            case .failure(let problems):
                #expect(problems.messages.contains { $0.contains("does not match") })
        }
    }

    @Test func `archive step passes appleSigning options only on macOS`() throws {
        let json = """
            {
              "release": {
                "executables": ["ask"],
                "appleSigning": { "sign": true, "identifier": "ask", "notarize": true }
              }
            }
            """
        let config = try configuration(json)
        let planner = StepPlanner(configuration: config, project: package, lock: .builtIn)

        let macSteps = try planner.steps(for: CheckID.archiveMacOS)
        guard case .archive(let exe, let os, let signing) = macSteps.last else {
            Issue.record("expected archive step on macOS")
            return
        }
        #expect(exe == "ask" && os == .macOS)
        #expect(signing == AppleSigning.Options(sign: true, identifier: "ask", notarize: true))

        let linuxSteps = try planner.steps(for: CheckID.archiveLinux)
        guard case .archive(_, let linuxOS, let linuxSigning) = linuxSteps.last else {
            Issue.record("expected archive step on Linux")
            return
        }
        #expect(linuxOS == .linux && linuxSigning == nil)
    }
}
