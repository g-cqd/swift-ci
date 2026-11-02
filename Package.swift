// swift-tools-version:6.2
import PackageDescription

// No dependencies: the CLI builds in seconds on any runner, before anything else of the project is known.
let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "swift-ci",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-ci", targets: ["swift-ci"]),
        .library(name: "SwiftCIKit", targets: ["SwiftCIKit"]),
        .plugin(name: "SwiftCIPlugin", targets: ["SwiftCIPlugin"])
    ],
    targets: [
        .target(name: "SwiftCIKit", swiftSettings: settings),
        .executableTarget(name: "swift-ci", dependencies: ["SwiftCIKit"], swiftSettings: settings),
        .plugin(
            name: "SwiftCIPlugin",
            capability: .command(
                intent: .custom(
                    verb: "swift-ci",
                    description: "Plan, run and check CI stages locally, as CI runs them."
                )
            ),
            dependencies: ["swift-ci"]
        ),
        .testTarget(
            name: "SwiftCIKitTests",
            dependencies: ["SwiftCIKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: settings
        )
    ]
)
