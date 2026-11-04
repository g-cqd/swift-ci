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
                "0.17.4",
                mac: "c3c37a8050456d944ae9ac7709298100aa67d9be3d943bede427d954488452b7",
                linux: "2a12b2fd1ec465e8d64538cb89ef594f725edb5096168205e89616527f0d9b25"
            ),
            gcqd(
                "deadwood",
                "0.15.4",
                mac: "5e8c28a7de9d9cfe82aad5832af3de699be4df68bbb0e4373c31d5ac1e24e03f",
                linux: "3350a50fee3cfc4d07b11a9ce77c8bc94a609d111699bca4e427092374c59579"
            ),
            gcqd(
                "dolly",
                "0.14.4",
                mac: "aceeff75dcce7d4e6aebf634df7bad947f62226f45a65289579b0c292f8af84f",
                linux: "ce1ada1a69877a9c8464862d19b32aa595b15d17610100ca1b24dc3c62225946"
            ),
            gcqd(
                "fcheck",
                "0.4.8",
                mac: "5f6ec32ecd94c956fe4703690c99590e91dae0f3de8333914345360c7b6bd18d",
                linux: "5eed49fad58d84aec265581647e10310860b36cf3edba4d42383d9bdfb89775c"
            ),
            gcqd(
                "modeler",
                "0.4.7",
                mac: "61e2f9ccbb3266f8fa950681b06afb0dffae3101d35a0f7d50cc91148db7450b",
                linux: "c9f137af946ff887623013d309104fc6e5f6a89301e2948538f7a267884d7207",
                command: "check"
            ),
            // Local-only (mutation testing on this machine); macOS arm64 is the only published archive.
            Tool(
                name: "litmus",
                version: "0.3.2",
                archives: [
                    Platform.macOSArm64.rawValue: .init(
                        url:
                            "https://github.com/g-cqd/litmus/releases/download/v{version}/litmus-{version}-macos-arm64.tar.gz",
                        sha256: "9651dd09f8b22dc93f2b03e3befe8e4a49c0fff583c28f134c713070223916c5"
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
