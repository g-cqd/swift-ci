/// A path pattern, as `.gitignore` spells them: `*` is any run of characters but `/`, `?` one character but `/`,
/// `**` any run of whole directories (none included). A pattern without `/` matches a file's name in any directory.
public struct Glob: Sendable, Hashable, CustomStringConvertible {
    public let pattern: String
    private let parts: [UInt8]

    public init(_ pattern: String) {
        self.pattern = pattern
        let anchored = pattern.contains("/") ? pattern : "**/" + pattern
        parts = Array((anchored.hasPrefix("/") ? String(anchored.dropFirst()) : anchored).utf8)
    }

    public var description: String { pattern }

    /// Whether `path`, relative to the repository root without a leading `/`, matches.
    public func matches(_ path: String) -> Bool {
        Self.match(parts[...], Array(path.utf8)[...])
    }

    private static let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), question = UInt8(ascii: "?")

    private static func match(_ pattern: ArraySlice<UInt8>, _ path: ArraySlice<UInt8>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == star, pattern.dropFirst().first == star {
            var rest = pattern.dropFirst(2)
            // `**/` matches no directory or several whole ones; a trailing `**` matches everything left.
            if rest.first == slash {
                rest = rest.dropFirst()
                if match(rest, path) { return true }
                var index = path.startIndex
                while let next = path[index...].firstIndex(of: slash) {
                    if match(rest, path[(next + 1)...]) { return true }
                    index = next + 1
                }
                return false
            }
            return rest.isEmpty
                ? true : (path.indices.contains { match(rest, path[$0...]) } || match(rest, path[path.endIndex...]))
        }
        if first == star {
            let rest = pattern.dropFirst()
            var index = path.startIndex
            while true {
                if match(rest, path[index...]) { return true }
                guard index < path.endIndex, path[index] != slash else { return false }
                index += 1
            }
        }
        guard let character = path.first else { return false }
        if first == question ? character != slash : character == first {
            return match(pattern.dropFirst(), path.dropFirst())
        }
        return false
    }
}
