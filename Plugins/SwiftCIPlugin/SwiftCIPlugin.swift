import Foundation
import PackagePlugin

/// `swift package swift-ci <command>`: the CLI from inside a package, on the package's own directory. Running checks
/// builds and tests and installs tools, so use `swift package --disable-sandbox swift-ci run …`; `plan`, `steps`,
/// `detect` and `validate` only read.
@main
struct SwiftCIPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "swift-ci")
        let process = Process()
        process.executableURL = tool.url
        process.arguments =
            arguments.contains("--root") ? arguments : arguments + ["--root", context.package.directoryURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            Diagnostics.error("swift-ci \(arguments.joined(separator: " ")) failed (\(process.terminationStatus))")
            return
        }
    }
}
