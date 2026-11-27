public import Foundation

/// A fresh checkout gives every file the time of the checkout, so a build restored from the cache compiles everything
/// again: the compiler sees every source as newer than what it built. The times the files had when the cached build was
/// made are kept beside it, by the git object of each file's content; after the next checkout, a file whose content is
/// the same object gets its time back, and only what changed is compiled again.
public enum SourceTimes {
    /// Where the times are kept: inside `.build`, which the cache holds.
    public static let manifest = ".build/swift-ci/source-times.tsv"

    /// One tracked file: its path, the git object of its content, and its time (seconds since 1970, to the nanosecond).
    struct Entry: Equatable {
        var path: String
        var object: String
        var time: Double
    }

    /// The tracked files of the package at `root` with their objects (`git ls-files -s`).
    static func tracked(root: URL) -> [(path: String, object: String)] {
        guard let output = try? Shell.output(["git", "ls-files", "-s", "-z"], directory: root, quiet: true) else {
            return []
        }
        return output.split(separator: "\0")
            .compactMap { record in
                // "<mode> <object> <stage>\t<path>"
                let parts = record.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let fields = parts[0].split(separator: " ")
                guard fields.count == 3 else { return nil }
                return (String(parts[1]), String(fields[1]))
            }
    }

    /// Writes the times the tracked files have now.
    public static func save(root: URL) {
        let manager = FileManager.default
        let lines = tracked(root: root)
            .compactMap { file -> String? in
                let url = root.appendingPathComponent(file.path)
                guard let date = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                    return nil
                }
                return "\(file.object)\t\(date.timeIntervalSince1970)\t\(file.path)"
            }
        let url = root.appendingPathComponent(manifest)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    /// Gives each tracked file whose content is the one the times were kept with its kept time; how many it gave back.
    @discardableResult
    public static func restore(root: URL) -> Int {
        guard let text = try? String(contentsOf: root.appendingPathComponent(manifest), encoding: .utf8) else {
            return 0
        }
        let kept = Dictionary(parse(text).map { ($0.path, $0) }) { first, _ in first }
        var restored = 0
        for file in tracked(root: root) {
            guard let entry = kept[file.path], entry.object == file.object else { continue }
            let date = Date(timeIntervalSince1970: entry.time)
            let path = root.appendingPathComponent(file.path).path
            if (try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)) != nil {
                restored += 1
            }
        }
        return restored
    }

    /// The manifest's lines: "<object>\t<time>\t<path>"; others are left out.
    static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3, let time = Double(parts[1]) else { return nil }
                return Entry(path: String(parts[2]), object: String(parts[0]), time: time)
            }
    }
}
