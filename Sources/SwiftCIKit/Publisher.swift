public import Foundation

/// Publishes a tag: the archives both OS jobs made, an artifact bundle per executable, and the release note with its
/// Archives section filled. Refuses to publish without a macOS archive of each executable, or with an archive whose
/// `.sha256` does not match.
public struct Publisher {
    public var root: URL
    public var assets: URL
    public var tag: String
    public var configuration: Configuration
    public var dryRun: Bool

    public init(root: URL, assets: URL, tag: String, configuration: Configuration, dryRun: Bool = false) {
        self.root = root
        self.assets = assets
        self.tag = tag
        self.configuration = configuration
        self.dryRun = dryRun
    }

    public func publish(repository: String) throws {
        guard let release = configuration.release, !release.executables.isEmpty else {
            throw SwiftCIError("no release.executables to publish")
        }
        let files = FileManager.default
        let names = try files.contentsOfDirectory(atPath: assets.path).sorted()
        for name in names where name.hasSuffix(".tar.gz") {
            let expected = try ReleaseNote.assets(in: assets).first { $0.name == name }?.digest
            let actual = try Shell.sha256(of: assets.appendingPathComponent(name))
            guard expected == actual else {
                throw SwiftCIError("\(name): SHA-256 \(actual) is not its .sha256's \(expected ?? "(none)")")
            }
        }
        for executable in release.executables {
            let archives = names.compactMap { name in
                ArtifactBundle.parse(archive: name, tool: executable).map { (name, $0) }
            }
            guard archives.contains(where: { $0.1.platform.hasPrefix("macos-") }) else {
                throw SwiftCIError(
                    "no macOS archive of \(executable): refusing to publish without the primary artifact"
                )
            }
            try bundle(executable, archives: archives)
        }

        let notePath = release.notes.replacingOccurrences(of: "{tag}", with: tag)
        let noteURL = root.appendingPathComponent(notePath)
        guard files.fileExists(atPath: noteURL.path) else {
            throw SwiftCIError("no release note at \(notePath): write it with the fixed sections before tagging")
        }
        let filled: String
        switch ReleaseNote.fill(
            try String(contentsOf: noteURL, encoding: .utf8),
            assets: try ReleaseNote.assets(in: assets)
        ) {
            case .success(let text): filled = text
            case .failure(let problems): throw SwiftCIError("release note \(notePath):\n\(problems)")
        }
        let filledURL = assets.appendingPathComponent("release-note.md")
        try filled.write(to: filledURL, atomically: true, encoding: .utf8)
        print(filled)

        let uploads = try files.contentsOfDirectory(atPath: assets.path).sorted()
            .filter { $0.hasSuffix(".tar.gz") || $0.hasSuffix(".zip") || $0.hasSuffix(".sha256") }
            .map { assets.appendingPathComponent($0).path }
        let exists = (try? Shell.output(["gh", "release", "view", tag, "--repo", repository])) != nil
        let commands: [[String]] =
            exists
            ? [
                ["gh", "release", "upload", tag, "--repo", repository, "--clobber"] + uploads,
                ["gh", "release", "edit", tag, "--repo", repository, "--notes-file", filledURL.path]
            ]
            : [["gh", "release", "create", tag, "--repo", repository, "--notes-file", filledURL.path] + uploads]
        for command in commands {
            if dryRun { print(command.map(ShellCommand.quote).joined(separator: " ")) } else { try Shell.run(command) }
        }
    }

    /// `<executable>-<version>.artifactbundle.zip` and its `.sha256`, from the unpacked archives.
    func bundle(_ executable: String, archives: [(String, (version: String, platform: String))]) throws {
        let files = FileManager.default
        guard let version = archives.first?.1.version else { return }
        let bundle = assets.appendingPathComponent("\(executable).artifactbundle")
        try? files.removeItem(at: bundle)
        var variants: [ArtifactBundle.Variant] = []
        for (name, parsed) in archives {
            guard let triple = ArtifactBundle.triple(platform: parsed.platform) else { continue }
            try Shell.run(["tar", "-xzf", name], directory: assets)
            let stem = String(name.dropLast(".tar.gz".count))
            let bin = bundle.appendingPathComponent("\(stem)/bin")
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            for file in try files.contentsOfDirectory(atPath: assets.appendingPathComponent(stem).path)
            where file == executable || file.contains(".so") {
                try files.copyItem(
                    at: assets.appendingPathComponent("\(stem)/\(file)"),
                    to: bin.appendingPathComponent(file)
                )
            }
            variants.append(.init(path: "\(stem)/bin/\(executable)", triple: triple))
        }
        try ArtifactBundle.info(tool: executable, version: version, variants: variants)
            .write(to: bundle.appendingPathComponent("info.json"))
        let zip = "\(executable)-\(version).artifactbundle.zip"
        try Shell.run(["zip", "-qr", zip, "\(executable).artifactbundle"], directory: assets)
        let digest = try Shell.sha256(of: assets.appendingPathComponent(zip))
        try "\(digest)  \(zip)\n"
            .write(to: assets.appendingPathComponent(zip + ".sha256"), atomically: true, encoding: .utf8)
    }
}
