import Foundation

/// Makes a macOS release executable runnable on machines other than the one that built it.
///
/// SwiftPM links back-deployment libraries (e.g. `libswiftCompatibilitySpan.dylib`, needed below the OS release that
/// ships `Span`) through `@rpath`, and records the build machine's toolchain directories as rpaths. On a user's Mac
/// without that toolchain the binary would not launch. The plan bundles each `@rpath` library found in those
/// directories beside the executable, removes the machine-specific rpaths, and makes sure `@loader_path` is searched
/// (after `/usr/lib/swift`, so an OS that ships the library uses its own copy).
public enum MachOPortability {
    public struct Plan: Equatable, Sendable {
        /// Absolute paths of the libraries to copy beside the executable.
        public var bundled: [String]
        /// `@rpath` libraries found in no rpath directory (left as they are; the binary needs them at run time).
        public var unresolved: [String]
        /// Machine-specific rpaths to delete.
        public var removedRpaths: [String]
        /// Whether `@loader_path` must be added as an rpath.
        public var addsLoaderPath: Bool

        public init(bundled: [String], unresolved: [String], removedRpaths: [String], addsLoaderPath: Bool) {
            self.bundled = bundled
            self.unresolved = unresolved
            self.removedRpaths = removedRpaths
            self.addsLoaderPath = addsLoaderPath
        }
    }

    /// Rpaths valid on every Mac.
    static let portableRpaths: Set<String> = ["/usr/lib/swift", "@loader_path", "@executable_path"]

    /// The plan for a binary whose `otool -l` output is `otoolLoadCommands`; `exists` tells whether a file exists.
    public static func plan(otoolLoadCommands: String, exists: (String) -> Bool) -> Plan {
        let (libraries, rpaths) = parse(otoolLoadCommands)
        var bundled: [String] = []
        var unresolved: [String] = []
        for library in libraries {
            let name = String(library.dropFirst("@rpath/".count))
            let candidates = rpaths.filter { !portableRpaths.contains($0) && $0.hasPrefix("/") }
            if let found = candidates.map({ "\($0)/\(name)" }).first(where: exists) {
                bundled.append(found)
            } else {
                unresolved.append(name)
            }
        }
        let removed = rpaths.filter { !portableRpaths.contains($0) && !$0.hasPrefix("@") }
        return Plan(
            bundled: bundled,
            unresolved: unresolved,
            removedRpaths: removed,
            addsLoaderPath: !bundled.isEmpty && !rpaths.contains("@loader_path")
        )
    }

    /// The `@rpath/…` dylib names and the rpaths, in load-command order.
    static func parse(_ otool: String) -> (libraries: [String], rpaths: [String]) {
        var libraries: [String] = []
        var rpaths: [String] = []
        var command = ""
        for rawLine in otool.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cmd ") {
                command = String(line.dropFirst(4))
            } else if line.hasPrefix("name "), command == "LC_LOAD_DYLIB" || command == "LC_LOAD_WEAK_DYLIB" {
                let name = value(of: line, after: "name ")
                if name.hasPrefix("@rpath/") { libraries.append(name) }
            } else if line.hasPrefix("path "), command == "LC_RPATH" {
                rpaths.append(value(of: line, after: "path "))
            }
        }
        return (libraries, rpaths)
    }

    /// `name /x/y (offset 24)` → `/x/y`.
    private static func value(of line: String, after prefix: String) -> String {
        var text = Substring(line.dropFirst(prefix.count))
        if let range = text.range(of: " (offset ", options: .backwards) { text = text[..<range.lowerBound] }
        return String(text)
    }
}
