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
            File(path: ".github/workflows/ci.yml", contents: workflow(ref: ref)),
            File(path: bootstrapPath, contents: bootstrap)
        ]
    }

    /// `.ci/swift-ci`: runs swift-ci at the commit the workflow pins, so `.ci/swift-ci local` checks what CI checks.
    public static let bootstrapPath = ".ci/swift-ci"

    /// The bootstrap's contents. `swift-ci validate` requires a repository's copy to be exactly this.
    public static let bootstrap = #"""
        #!/bin/bash
        # swift-ci at the commit this repository's CI pins (.github/workflows/ci.yml): a local run checks what CI checks.
        #
        #   .ci/swift-ci local          the checks .ci/action.json lists in localChecks (default: quality, debug tests)
        #   .ci/swift-ci run quality    one check, as CI runs it
        #
        # Written by `swift-ci bootstrap`; `swift-ci validate` refuses a copy that differs. SWIFT_CI_SOURCE=<checkout>
        # builds that swift-ci instead of the pinned one (to try a change to swift-ci itself).
        set -euo pipefail
        root="$(cd "$(dirname "$0")/.." && pwd)"
        home="${SWIFT_CI_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/swift-ci}"
        if [ -n "${SWIFT_CI_SOURCE:-}" ]; then
            swift build -c release --package-path "$SWIFT_CI_SOURCE" --product swift-ci >&2
            exec "$(swift build -c release --package-path "$SWIFT_CI_SOURCE" --show-bin-path)/swift-ci" "$@" --root "$root"
        fi
        pin="$(grep -oE 'g-cqd/swift-ci/\.github/workflows/swift-ci\.yml@[0-9a-f]{40}' "$root/.github/workflows/ci.yml" \
            | head -n 1 | cut -d@ -f2 || true)"
        if [ -z "$pin" ]; then
            echo "swift-ci: no pinned commit of g-cqd/swift-ci in .github/workflows/ci.yml" >&2
            exit 2
        fi
        cli="$home/$pin/swift-ci"
        if [ ! -x "$cli" ]; then
            work="$(mktemp -d "${TMPDIR:-/tmp}/swift-ci-build.XXXXXX")"
            if ! (
                git -C "$work" init -q &&
                    git -C "$work" fetch -q --depth 1 https://github.com/g-cqd/swift-ci.git "$pin" &&
                    git -C "$work" checkout -q FETCH_HEAD &&
                    swift build -c release --package-path "$work" --product swift-ci > "$work/build.log" 2>&1
            ); then
                cat "$work/build.log" >&2 2> /dev/null || true
                rm -rf "$work"
                echo "swift-ci: could not build swift-ci $pin" >&2
                exit 2
            fi
            mkdir -p "$home/$pin"
            # Copied then renamed: a concurrent run never sees a partial binary.
            cp "$(swift build -c release --package-path "$work" --show-bin-path)/swift-ci" "$cli.$$"
            mv -f "$cli.$$" "$cli"
            rm -rf "$work"
        fi
        exec "$cli" "$@" --root "$root"

        """#

    /// Whether the bootstrap at `root` is missing or current; an edited or outdated one is an error to fix with
    /// `swift-ci bootstrap`.
    public static func checkBootstrap(root: URL) throws {
        let url = root.appendingPathComponent(bootstrapPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard (try? String(contentsOf: url, encoding: .utf8)) == bootstrap else {
            throw SwiftCIError(
                "\(bootstrapPath) is not this swift-ci's bootstrap: run `swift-ci bootstrap` to replace it"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw SwiftCIError("\(bootstrapPath) is not executable: run `swift-ci bootstrap`")
        }
    }

    /// Writes (or replaces) the bootstrap at `root`, executable.
    public static func writeBootstrap(root: URL) throws {
        let url = root.appendingPathComponent(bootstrapPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bootstrap.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
            if file.path == bootstrapPath {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
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
