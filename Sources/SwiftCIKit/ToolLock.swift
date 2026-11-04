public import Foundation

/// The tools quality runs, pinned: a version and, per platform, an archive URL and its SHA-256. A tool is never run
/// unless its archive has the pinned hash and the binary reports the pinned version, so a check cannot change because
/// a tool moved under it. A project can replace the built-in lock with `quality.lock`.
public struct ToolLock: Codable, Sendable, Equatable {
    public var tools: [Tool]

    public struct Tool: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        /// The archive per platform (``ToolLock/Platform``).
        public var archives: [String: Archive]
        /// The binary inside the archive; `{version}` and `{platform}` are replaced.
        public var binary: String
        /// The arguments of a run before the paths it reads; nil for a formatter, which quality drives itself.
        public var arguments: [String]?

        public init(name: String, version: String, archives: [String: Archive], binary: String, arguments: [String]?) {
            self.name = name
            self.version = version
            self.archives = archives
            self.binary = binary
            self.arguments = arguments
        }

        public struct Archive: Codable, Sendable, Equatable {
            /// `{version}` is replaced.
            public var url: String
            public var sha256: String
            /// The binary inside this archive when it is not the tool's ``Tool/binary``.
            public var binary: String?

            public init(url: String, sha256: String, binary: String? = nil) {
                self.url = url
                self.sha256 = sha256
                self.binary = binary
            }
        }

        public func archive(for platform: Platform) throws -> (url: String, sha256: String) {
            guard let archive = archives[platform.rawValue] else {
                throw SwiftCIError("\(name) \(version) has no archive for \(platform.rawValue) in the lock")
            }
            return (archive.url.replacingOccurrences(of: "{version}", with: version), archive.sha256.lowercased())
        }

        public func binaryPath(for platform: Platform) -> String {
            (archives[platform.rawValue]?.binary ?? binary).replacingOccurrences(of: "{version}", with: version)
                .replacingOccurrences(of: "{platform}", with: platform.rawValue)
        }
    }

    /// A platform archives are published for.
    public enum Platform: String, Sendable, CaseIterable {
        case macOSArm64 = "macos-arm64"
        case linuxX86_64 = "linux-x86_64"

        /// This machine's.
        public static var current: Platform? {
            #if os(macOS) && arch(arm64)
                .macOSArm64
            #elseif os(Linux) && arch(x86_64)
                .linuxX86_64
            #else
                nil
            #endif
        }
    }

    public func tool(named name: String) throws -> Tool {
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw SwiftCIError("\(name) is not in the tool lock (it has: \(tools.map(\.name).joined(separator: ", ")))")
        }
        return tool
    }

    /// Checks every entry is complete: a version, a 64-digit hash per archive, an `https` URL.
    public func validate() throws {
        var names = Set<String>()
        for tool in tools {
            guard names.insert(tool.name).inserted else { throw SwiftCIError("tool lock: \(tool.name) appears twice") }
            guard !tool.version.isEmpty else { throw SwiftCIError("tool lock: \(tool.name) has no version") }
            for (platform, archive) in tool.archives {
                guard Platform(rawValue: platform) != nil else {
                    throw SwiftCIError("tool lock: \(tool.name): unknown platform \(platform)")
                }
                guard archive.sha256.count == 64, archive.sha256.allSatisfy(\.isHexDigit) else {
                    throw SwiftCIError("tool lock: \(tool.name) \(platform): the SHA-256 is not 64 hexadecimal digits")
                }
                guard archive.url.hasPrefix("https://") else {
                    throw SwiftCIError("tool lock: \(tool.name) \(platform): not an https URL")
                }
            }
        }
    }

    public static func decode(_ data: Data) throws -> ToolLock {
        let lock = try JSONDecoder().decode(ToolLock.self, from: data)
        try lock.validate()
        return lock
    }

    /// The lock `configuration` names, else `.ci/tools.lock.json` when there is one, else the built-in one.
    public static func load(root: URL, configuration: Configuration) throws -> ToolLock {
        let named = configuration.quality.lock
        let path = named ?? CIFolder.toolLock
        let url = root.appendingPathComponent(path)
        guard named != nil || FileManager.default.fileExists(atPath: url.path) else { return builtIn }
        do {
            return try decode(try Data(contentsOf: url))
        } catch let error as SwiftCIError {
            throw SwiftCIError("\(path): \(error.description)")
        } catch {
            throw SwiftCIError("\(path): \(error.localizedDescription)")
        }
    }

    // swift-format comes with the toolchain (`swift format`), so it is not locked. The hashes below are those of the
    // published archives, computed on 2026-11-02 (the g-cqd ones are aemi's Scripts/analyzers.lock).
    public static let builtIn: ToolLock = {
        func gcqd(_ name: String, _ version: String, mac: String, linux: String, command: String = "analyze") -> Tool {
            let base = "https://github.com/g-cqd/\(name)/releases/download/v{version}/\(name)-{version}"
            return Tool(
                name: name,
                version: version,
                archives: [
                    Platform.macOSArm64.rawValue: .init(url: base + "-macos-arm64.tar.gz", sha256: mac),
                    Platform.linuxX86_64.rawValue: .init(url: base + "-linux-x86_64.tar.gz", sha256: linux)
                ],
                binary: "\(name)-{version}-{platform}/\(name)",
                arguments: [command, "--strict", "--no-cache", "--relative-to", "."]
            )
        }
        /// A formatter from its project's releases: the archive, its hash and the binary inside, per platform.
        func upstream(
            _ name: String,
            _ version: String,
            _ base: String,
            mac: (String, String, String),
            linux: (String, String, String)
        ) -> Tool {
            Tool(
                name: name,
                version: version,
                archives: [
                    Platform.macOSArm64.rawValue: .init(url: base + mac.0, sha256: mac.1, binary: mac.2),
                    Platform.linuxX86_64.rawValue: .init(url: base + linux.0, sha256: linux.1, binary: linux.2)
                ],
                binary: name,
                arguments: nil
            )
        }
        return ToolLock(tools: [
            gcqd(
                "arcleak",
                "0.17.3",
                mac: "9759490a2fefdf6a4c9836a48b536f1cdc0f7f4a0cefa448be56eebdad86b7c6",
                linux: "f676e5b7ca9b47fb35b6fa7efe768a0bd18e6bfb4a3bffeee6db7f7cb537090f"
            ),
            gcqd(
                "deadwood",
                "0.15.3",
                mac: "fb9e6b61f1156f8972e7e0911376e0871a73cce178846012c6a6f1f3ca01c95f",
                linux: "45c01385027b02c8bde6d728435d81aeb45fc352504e356beb564ec83bbe58d5"
            ),
            gcqd(
                "dolly",
                "0.14.3",
                mac: "2dbc2c8167e5164729d11b24a232d70b2f09dd37f9188a78ea1bdc94a0ac3fba",
                linux: "9d91b64ab2c9d9aa79037aae8b72851cdd52ede21aae51c2b6638020962247cd"
            ),
            gcqd(
                "fcheck",
                "0.4.7",
                mac: "9ac466e54e541d183915c44706a11b3b431a37d49fd45d9136cf1c1c11bc7e9f",
                linux: "76d943227bd3831d2eb65982c460cab623aaffcb8db014ba47fd8e4cbc28abde"
            ),
            gcqd(
                "modeler",
                "0.4.6",
                mac: "e75f2b486f5095dc6baefe49a80bd264f0bd392d42437f0206edbf3ba06ce13c",
                linux: "ca722da139cd3baf4db1aed5f2bccd52e47ed284221db2ce419d4df379e92067",
                command: "check"
            ),
            // Local-only (mutation testing on this machine); macOS arm64 is the only published archive.
            Tool(
                name: "litmus",
                version: "0.3.1",
                archives: [
                    Platform.macOSArm64.rawValue: .init(
                        url:
                            "https://github.com/g-cqd/litmus/releases/download/v{version}/litmus-{version}-macos-arm64.tar.gz",
                        sha256: "eaa1cbc2b5e7f5fb2eebb9385c4ad367fd8653c417fc91ea55a4070f0a26f21f"
                    )
                ],
                binary: "litmus-{version}-{platform}/litmus",
                arguments: nil
            ),
            upstream(
                "swiftlint",
                "0.65.1",
                "https://github.com/realm/SwiftLint/releases/download/{version}/",
                mac: (
                    "portable_swiftlint.zip", "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
                    "swiftlint"
                ),
                linux: (
                    "swiftlint_linux_amd64.zip", "caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d",
                    "swiftlint"
                )
            ),
            upstream(
                "swiftformat",
                "0.64.5",
                "https://github.com/nicklockwood/SwiftFormat/releases/download/{version}/",
                mac: (
                    "swiftformat.zip", "ec017c91fdd46233e5a22dc43ff9564a3cc4b37023d3b4681b6c7d7b781de113", "swiftformat"
                ),
                linux: (
                    "swiftformat_linux.zip", "56c50d955903cfedbe28996a70e7551a873cdb6dfa5e416d9332925c455ab365",
                    "swiftformat_linux"
                )
            )
        ])
    }()
}
