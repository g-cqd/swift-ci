public import Foundation

/// A package's `.build` kept as a symbolic link to a directory outside the sources (a cache volume, say). When the
/// target is gone, SwiftPM fails with "The file “<package>” couldn’t be saved in the folder “<parent>”", naming
/// neither `.build` nor the link. swift-ci recreates the target before it runs SwiftPM, and says so.
public enum BuildLink {
    /// The SwiftPM commands that write into `.build`.
    static let subcommands: Set<String> = ["build", "test", "run", "package"]

    /// The package directory, relative to the root, whose `.build` `arguments` writes into: nil when the command is
    /// not SwiftPM's or names its own `--scratch-path`.
    public static func packageDirectory(of arguments: [String]) -> String? {
        guard arguments.count >= 2, arguments[0] == "swift", subcommands.contains(arguments[1]) else { return nil }
        guard !arguments.contains(where: { $0 == "--scratch-path" || $0.hasPrefix("--scratch-path=") }) else {
            return nil
        }
        if let index = arguments.firstIndex(of: "--package-path"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        return arguments.first { $0.hasPrefix("--package-path=") }.map { String($0.dropFirst("--package-path=".count)) }
            ?? "."
    }

    /// Creates the missing target of `directory/.build` when it is a dangling symbolic link, and returns a note
    /// saying so; nil when there is nothing to do.
    public static func repair(packageDirectory directory: URL) throws -> String? {
        let link = directory.appendingPathComponent(".build").standardizedFileURL
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        let target =
            destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination) : directory.appendingPathComponent(destination)
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw SwiftCIError(
                "\(link.path) is a symbolic link to \(destination), which does not exist and cannot be created: \(error)"
            )
        }
        return "swift-ci: \(link.path) pointed to \(destination), which did not exist; created it"
    }
}
