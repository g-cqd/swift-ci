import Foundation
import SwiftCIKit
import Testing

/// A temporary directory holding the given files (path → contents), removed when the scope ends.
struct Sandbox: ~Copyable {
    let root: URL

    init(_ files: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-ci-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

func configuration(_ json: String) throws -> Configuration {
    try Configuration.decode(Data(json.utf8))
}

let package = Project(kind: .package, linux: true, formatters: [.swiftFormat], corpus: ["Sources", "Tests"])

/// The test bundle's fixtures directory.
func fixtures(_ path: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
}

/// The command lines of `steps`, as a shell would show them.
func commandLines(_ steps: [Step]) -> [String] {
    steps.map { step in
        switch step {
            case .run(let command): command.description
            case .shell(_, let script): "sh: " + script
            case .install(let tool): "install \(tool.name)"
            case .tool(let name, _, let arguments): ([name] + arguments).joined(separator: " ")
            case .archive(let executable, let os): "archive \(executable) \(os.rawValue)"
            case .file(let path, _): "write \(path)"
            case .discipline(let discipline): "discipline " + discipline.shipped.joined(separator: " ")
            case .swiftFormat(let files):
                SwiftFormatLint.arguments(configuration: ".swift-format", files: files).joined(separator: " ")
            case .tla(_, let models): "tla " + models.models
            case .git(_, let fixtures): fixtures.map { "git \($0.git)@\($0.commit) \($0.into)" }.joined(separator: "; ")
            case .benchmark(_, let comparison): "benchmark " + comparison.package
        }
    }
}
