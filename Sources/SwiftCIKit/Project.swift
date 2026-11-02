public import Foundation

/// What a repository holds, read from its files: the kind of project, the formatters it configures, and what the
/// analyzers read.
public struct Project: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case package
        case xcodeWorkspace = "xcode-workspace"
        case xcodeProject = "xcode-project"
    }

    public var kind: Kind
    /// The `.xcworkspace` or `.xcodeproj`, relative to the root (Xcode).
    public var xcode: String?
    /// Whether the project builds on Linux.
    public var linux: Bool
    /// The formatters and linters to run.
    public var formatters: [Formatter]
    /// What the analyzers read.
    public var corpus: [String]

    public init(kind: Kind, xcode: String? = nil, linux: Bool, formatters: [Formatter], corpus: [String]) {
        self.kind = kind
        self.xcode = xcode
        self.linux = linux
        self.formatters = formatters
        self.corpus = corpus
    }

    public var isXcode: Bool { kind != .package }

    /// Reads the project at `root` as `configuration` describes it. An Xcode project needs schemes, unless
    /// `requireSchemes` is false (`swift-ci init`, which finds them).
    public static func detect(root: URL, configuration: Configuration, requireSchemes: Bool = true) throws -> Project {
        let files = FileManager.default
        let entries = (try? files.contentsOfDirectory(atPath: root.path)) ?? []
        let exists = { (name: String) in files.fileExists(atPath: root.appendingPathComponent(name).path) }

        let kind: Kind
        var xcode = configuration.project.xcode
        switch configuration.project.kind {
            case .package:
                guard exists("Package.swift") else {
                    throw SwiftCIError("project.kind is package, but there is no Package.swift")
                }
                kind = .package
            case .xcode, .auto:
                if xcode == nil, configuration.project.kind == .xcode || !exists("Package.swift") {
                    let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }.sorted()
                    let projects = entries.filter { $0.hasSuffix(".xcodeproj") }.sorted()
                    let candidates = workspaces.isEmpty ? projects : workspaces
                    if candidates.count > 1 {
                        throw SwiftCIError(
                            "several Xcode projects (\(candidates.joined(separator: ", "))): name one in project.xcode"
                        )
                    }
                    xcode = candidates.first
                }
                if let path = xcode {
                    guard exists(path) else { throw SwiftCIError("project.xcode: no \(path)") }
                    kind = path.hasSuffix(".xcworkspace") ? .xcodeWorkspace : .xcodeProject
                } else if exists("Package.swift") {
                    kind = .package
                } else {
                    throw SwiftCIError("no Package.swift, .xcworkspace or .xcodeproj at \(root.path)")
                }
        }
        if kind != .package, requireSchemes, configuration.project.schemes.isEmpty {
            throw SwiftCIError("an Xcode project needs project.schemes")
        }

        let formatters: [Formatter] =
            switch configuration.quality.formatters {
                case .auto: Formatter.allCases.filter { exists($0.configurationFile) }
                case .only(let list): list
            }
        var corpus = configuration.quality.paths
        if corpus.isEmpty {
            corpus = ["Sources", "Tests"].filter(exists)
            if corpus.isEmpty { corpus = ["."] }
        }
        return Project(
            kind: kind,
            xcode: kind == .package ? nil : xcode,
            linux: configuration.project.linux ?? (kind == .package),
            formatters: formatters,
            corpus: corpus
        )
    }
}
