public import Foundation

/// What `swift-ci init` writes into a project: `.ci/action.json` and the workflow that calls swift-ci. Nothing that
/// exists is overwritten.
public enum Scaffold {
    public struct File: Equatable, Sendable {
        public var path: String
        public var contents: String
    }

    /// The files for `project`, the workflow pinned to `ref` (a commit of swift-ci, or a branch until there is one).
    public static func files(project: Project, schemes: [String], ref: String) throws -> [File] {
        var configuration: [String: Any] = [:]
        if project.isXcode {
            var settings: [String: Any] = ["schemes": schemes]
            if let xcode = project.xcode { settings["xcode"] = xcode }
            configuration["project"] = settings
            // The selected Xcode's toolchain: an app builds with what Xcode ships.
            configuration["swift"] = ["macOS": "xcode"]
        }
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
        let text = configuration.isEmpty ? "{}" : String(decoding: data, as: UTF8.self)
        return [
            File(path: CIFolder.configuration, contents: text + "\n"),
            File(path: ".github/workflows/ci.yml", contents: workflow(ref: ref))
        ]
    }

    public static func workflow(ref: String) -> String {
        let pin =
            ref.count == 40 && ref.allSatisfy(\.isHexDigit) ? ref : "\(ref)  # pin a commit: a branch moves under you"
        return """
            name: CI

            # swift-ci plans and runs the checks from .ci/action.json (https://github.com/g-cqd/swift-ci).
            on:
              push:
                branches: [main]
                tags: ["v*"]
              pull_request:
              merge_group:
              schedule:
                - cron: "17 3 * * *"
              workflow_dispatch:

            permissions:
              contents: read

            jobs:
              ci:
                uses: g-cqd/swift-ci/.github/workflows/swift-ci.yml@\(pin)
                permissions:
                  contents: write # only used to publish a tag
                secrets: inherit

            """
    }

    /// Writes the files that do not exist yet; returns those written and those left as they were.
    public static func write(_ files: [File], root: URL) throws -> (written: [String], kept: [String]) {
        var written: [String] = []
        var kept: [String] = []
        for file in files {
            let url = root.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: url.path) {
                kept.append(file.path)
                continue
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
            written.append(file.path)
        }
        return (written, kept)
    }

    /// The schemes of `xcodebuild -list -json` output, for a project or a workspace.
    public static func schemes(fromXcodebuildList data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let container = (object["workspace"] ?? object["project"]) as? [String: Any]
        return container?["schemes"] as? [String] ?? []
    }
}
