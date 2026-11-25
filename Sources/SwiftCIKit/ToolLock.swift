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
            #elseif os(Linux) && arch(arm64)
                linuxArm64Fallback(rosetta: FileManager.default.fileExists(atPath: "/proc/sys/fs/binfmt_misc/rosetta"))
            #else
                nil
            #endif
        }

        /// What an arm64 Linux machine uses: no archive is published for it, but one that runs x86_64 programs through Rosetta
        /// (the owner's development VM) runs the Linux x86_64 ones.
        public static func linuxArm64Fallback(rosetta: Bool) -> Platform? {
            rosetta ? .linuxX86_64 : nil
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
    // published archives, computed on 2026-11-02, litmus and SwiftFormat on 2026-11-24 (the g-cqd ones are aemi's Scripts/analyzers.lock).
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
                "0.17.10",
                mac: "c704c464e45f93384bcf739cde6db044f4d20082e43bb92bac0a732cbf438f03",
                linux: "1df960f4966322757bf7eea3422d6bf98c94f429bfdc0bb93aaa03fbeb44c028"
            ),
            gcqd(
                "deadwood",
                "0.16.4",
                mac: "7dce2c4af747d681d8113789abbb8b8ceb4d34fd36f01a6603808dbde2ee924a",
                linux: "b164e9d9deb1cfe65415068bbaddb53b3fbab987046555e8d7fc20c5e8ee1b0d"
            ),
            gcqd(
                "dolly",
                "0.14.8",
                mac: "323161150e723f7f5b65737a2382e0089ce0216527c51286c595e96700444c90",
                linux: "c8907b5a7d8c49e7c35dc7d8bfd61b859cca2abfd6eee957f5b8abea228bb149"
            ),
            gcqd(
                "fcheck",
                "0.4.11",
                mac: "cd61d7c35460936f76143ae56feafdef9c77c6f32ea5e7ee8e823d8c25fd232d",
                linux: "f3fac172f43f27efbde3dc65f246f6ffee3fe271eef46c8316ef1059e8811be9"
            ),
            gcqd(
                "modeler",
                "0.4.9",
                mac: "9f98050d00555951bec9a9db1ffa3e466fc67ea2bf4fd9dd87f3658d097cbba8",
                linux: "174d567b55d47aebf3bbd354e33b3e25f7731130062c7c707a07d822d783afb8",
                command: "check"
            ),
            // Local-only (mutation testing on this machine); macOS arm64 is the only published archive.
            Tool(
                name: "litmus",
                version: "0.4.11",
                archives: [
                    Platform.macOSArm64.rawValue: .init(
                        url:
                            "https://github.com/g-cqd/litmus/releases/download/v{version}/litmus-{version}-macos-arm64.tar.gz",
                        sha256: "4823be8687be31c79bb5fb80265764920065e0f6013c2a936aa9f53d3c6fabec"
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
                "0.64.7",
                "https://github.com/nicklockwood/SwiftFormat/releases/download/{version}/",
                mac: (
                    "swiftformat.zip", "e82e224325cbd3403fc7b68caf6c917926dc106de3af875fca4b87e3c4634038", "swiftformat"
                ),
                linux: (
                    "swiftformat_linux.zip", "819aea026e1c630f46b234ed84481e56d9eb3cfe7024cd51b1af55169c8e13bb",
                    "swiftformat_linux"
                )
            )
        ])
    }()
}
