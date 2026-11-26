/// The Swift runtime libraries a dynamically linked Linux executable needs beside it in a release archive.
public enum LinuxRuntime {
    /// The resolved paths in `ldd` output that belong to a Swift toolchain (`…/usr/lib/swift/…`), wherever it is
    /// installed (`/usr` in the official images, `~/.local/share/swiftly/toolchains/<version>/usr` with swiftly).
    public static func librariesToBundle(lddOutput: String) -> [String] {
        var libraries: [String] = []
        for line in lddOutput.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 3, words[1] == "=>" else { continue }
            let path = String(words[2])
            if path.contains("/usr/lib/swift/"), !libraries.contains(path) {
                libraries.append(path)
            }
        }
        return libraries
    }
}
