public import Foundation

/// macOS Developer ID code signing and notarisation for release archives (promoted from `sunset`'s `release.yml` and
/// `notarize-app.sh`, usable by any executable package such as `ask`).
///
/// The workflow sets up a temporary keychain from `DEVELOPER_ID_P12` / `DEVELOPER_ID_P12_PASSWORD` and passes the
/// signing identity and optional App Store Connect notary credentials via environment variables. Secrets are read from
/// environment variables or `0600` temporary files and are never printed to logs.
public enum AppleSigning {
    /// Options controlling how a macOS executable is signed and optionally notarised before archiving.
    public struct Options: Codable, Sendable, Equatable {
        /// Whether macOS release archives should be signed with a Developer ID identity when credentials are present
        /// (or fail on a tag if credentials are missing when `requiredOnTag` is true).
        public var sign: Bool = false
        /// Code signing identifier passed to `codesign --identifier` (defaults to the executable's name).
        public var identifier: String?
        /// Enable hardened runtime (`--options runtime`). Defaults to true, required for notarisation and Keychain
        /// protection (`DYLD_INSERT_LIBRARIES` isolation).
        public var hardenedRuntime: Bool = true
        /// Submit the signed binary archive to Apple's notary service (`xcrun notarytool submit --wait`) when notary
        /// credentials are present.
        public var notarize: Bool = false
        /// Fail on a tag run if signing credentials are missing (on `workflow_dispatch` unsigned checks are allowed).
        public var requireOnTag: Bool = true

        public init(
            sign: Bool = false,
            identifier: String? = nil,
            hardenedRuntime: Bool = true,
            notarize: Bool = false,
            requireOnTag: Bool = true
        ) {
            self.sign = sign
            self.identifier = identifier
            self.hardenedRuntime = hardenedRuntime
            self.notarize = notarize
            self.requireOnTag = requireOnTag
        }
    }

    /// Runtime credentials discovered from the environment (populated by the reusable workflow's signing step or a
    /// developer's shell). None of the secret values are included in `description`.
    public struct Credentials: Sendable, Equatable {
        /// Identity passed to `codesign --sign` (e.g. `Developer ID Application` or a SHA-1/name).
        public var identity: String
        /// Optional keychain path to pass to `codesign --keychain` (keeps CI signing isolated to its temporary keychain).
        public var keychain: String?
        /// Path to an App Store Connect API `.p8` key file for `xcrun notarytool`.
        public var notaryKeyPath: String?
        public var notaryKeyID: String?
        public var notaryIssuer: String?
        /// Optional `notarytool` keychain profile name (for local developer runs).
        public var notaryProfile: String?

        public init(
            identity: String,
            keychain: String? = nil,
            notaryKeyPath: String? = nil,
            notaryKeyID: String? = nil,
            notaryIssuer: String? = nil,
            notaryProfile: String? = nil
        ) {
            self.identity = identity
            self.keychain = keychain
            self.notaryKeyPath = notaryKeyPath
            self.notaryKeyID = notaryKeyID
            self.notaryIssuer = notaryIssuer
            self.notaryProfile = notaryProfile
        }

        public var hasNotaryCredentials: Bool {
            if let profile = notaryProfile, !profile.isEmpty { return true }
            guard let path = notaryKeyPath, !path.isEmpty,
                let keyID = notaryKeyID, !keyID.isEmpty,
                let issuer = notaryIssuer, !issuer.isEmpty
            else { return false }
            return true
        }

        /// Reads signing credentials from environment variables:
        /// - `SWIFT_CI_SIGN_IDENTITY` (preferred)
        /// - `SWIFT_CI_SIGN_KEYCHAIN` (optional)
        /// - `SWIFT_CI_NOTARY_KEY_PATH`, `SWIFT_CI_NOTARY_KEY_ID`, `SWIFT_CI_NOTARY_ISSUER`, or
        ///   `SWIFT_CI_NOTARY_PROFILE`
        public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
            -> Credentials?
        {
            guard let identity = env["SWIFT_CI_SIGN_IDENTITY"], !identity.isEmpty else { return nil }
            return Credentials(
                identity: identity,
                keychain: nonEmpty(env["SWIFT_CI_SIGN_KEYCHAIN"]),
                notaryKeyPath: nonEmpty(env["SWIFT_CI_NOTARY_KEY_PATH"]),
                notaryKeyID: nonEmpty(env["SWIFT_CI_NOTARY_KEY_ID"]),
                notaryIssuer: nonEmpty(env["SWIFT_CI_NOTARY_ISSUER"]),
                notaryProfile: nonEmpty(env["SWIFT_CI_NOTARY_PROFILE"])
            )
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    /// Builds the `codesign` command arguments for signing a standalone macOS executable.
    ///
    /// Uses `--timestamp` for real identities (required by Apple notarisation) and `--timestamp=none` for ad-hoc (`-`).
    public static func codesignArguments(
        binaryPath: String,
        executableName: String,
        options: Options,
        credentials: Credentials
    ) -> [String] {
        var args = ["codesign", "--force", "--sign", credentials.identity]
        args += ["--identifier", options.identifier ?? executableName]
        if let keychain = credentials.keychain { args += ["--keychain", keychain] }
        if options.hardenedRuntime { args += ["--options", "runtime"] }
        if credentials.identity == "-" {
            args.append("--timestamp=none")
        } else {
            args.append("--timestamp")
        }
        args.append(binaryPath)
        return args
    }

    /// Builds the `xcrun notarytool submit --wait` arguments for a zip archive.
    public static func notaryArguments(zipPath: String, credentials: Credentials) throws -> [String] {
        var args = ["xcrun", "notarytool", "submit", zipPath, "--wait"]
        if let path = credentials.notaryKeyPath, let keyID = credentials.notaryKeyID,
            let issuer = credentials.notaryIssuer
        {
            args += ["--key", path, "--key-id", keyID, "--issuer", issuer]
        } else if let profile = credentials.notaryProfile {
            args += ["--keychain-profile", profile]
        } else {
            throw SwiftCIError("notarisation requested without notary credentials")
        }
        return args
    }

    /// Signs a macOS executable and verifies its signature.
    public static func signExecutable(
        at binaryPath: String,
        executableName: String,
        options: Options,
        credentials: Credentials
    ) throws {
        try Shell.run(
            codesignArguments(
                binaryPath: binaryPath,
                executableName: executableName,
                options: options,
                credentials: credentials
            )
        )
        try Shell.run(["codesign", "--verify", "--strict", "--verbose=2", binaryPath])
    }

    /// Runs `body` inside a fresh temporary directory that is removed on return.
    public static func withTemporaryDirectory<T>(prefix: String = "swift-ci", _ body: (URL) throws -> T) throws -> T {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try body(scratch)
    }

    /// Submits a macOS standalone binary for notarisation by zipping it with `ditto` and waiting on `notarytool`.
    /// Note: standalone Mach-O binaries cannot be stapled (`stapler` requires an app bundle, `.pkg`, or `.dmg`);
    /// notarising registers the binary's CDHash with Apple's Gatekeeper ticket service.
    public static func notarizeExecutable(at binaryPath: String, executableName: String, credentials: Credentials)
        throws
    {
        try withTemporaryDirectory(prefix: "swift-ci-notary") { scratch in
            let zip = scratch.appendingPathComponent("\(executableName).zip")
            try Shell.run(["ditto", "-c", "-k", "--keepParent", binaryPath, zip.path])
            let result = try Shell.combinedOutput(notaryArguments(zipPath: zip.path, credentials: credentials))
            print(result.output, terminator: "")
            guard result.status == 0, result.output.contains("status: Accepted") else {
                throw SwiftCIError("notarisation of \(executableName) was not accepted")
            }
        }
    }
}
