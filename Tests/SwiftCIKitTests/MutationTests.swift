import Foundation
import SwiftCIKit
import Testing

struct MutationTests {
    private static let json = #"""
        {"commands": [{"id": "mutation", "title": "Verification · Mutation", "os": "macOS", "cadence": ["nightly", "dispatch"],
          "mutation": {"paths": ["Sources/A/**", "Sources/B/**"], "budget": 3600, "workspace": "in-place"}}]}
        """#

    @Test func `a mutation command runs the pinned litmus over its paths, then its verdict, strict without a baseline`()
        throws
    {
        let planner = StepPlanner(
            configuration: try configuration(Self.json),
            project: package,
            lock: .builtIn,
            mutationOutput: "/tmp/m"
        )
        let strict = try planner.steps(for: "mutation", swiftFiles: [], fileExists: { _ in false })
        #expect(
            commandLines(strict) == [
                "install litmus",
                "litmus run . --trust-project --workspace in-place --only-path Sources/A/** --only-path Sources/B/** "
                    + "--budget 3600 --output /tmp/m",
                "litmus analyze . --results /tmp/m/run.pb --strict"
            ]
        )
        let gated = try planner.steps(
            for: "mutation",
            swiftFiles: [],
            fileExists: { $0 == ".ci/baselines/litmus.json" }
        )
        #expect(
            commandLines(gated).last
                == "litmus analyze . --results /tmp/m/run.pb --baseline .ci/baselines/litmus.json --gate new-survivors"
        )
    }

    @Test func `a mutation command defaults to a copied workspace over every source, with no budget`() throws {
        let command = try configuration(#"{"commands": [{"id": "m", "os": "macOS", "mutation": {}}]}"#).commands[0]
        #expect(command.mutation == Mutation())
        let planner = StepPlanner(
            configuration: try configuration(#"{"commands": [{"id": "m", "os": "macOS", "mutation": {}}]}"#),
            project: package,
            lock: .builtIn,
            mutationOutput: "/tmp/m"
        )
        #expect(
            commandLines(try planner.steps(for: "m", swiftFiles: [], fileExists: { _ in false }))[1]
                == "litmus run . --trust-project --workspace copy --output /tmp/m"
        )
    }

    @Test
    func `a mutation command is refused off macOS, attached to a check, with another action, or with a bad field`()
        throws
    {
        let refused = [
            #"[{"id": "m", "mutation": {}}]"#,
            #"[{"id": "m", "os": "macOS", "after": "macos-debug", "mutation": {}}]"#,
            #"[{"id": "m", "os": "macOS", "before": ["macos-debug"], "mutation": {}}]"#,
            #"[{"id": "m", "os": "macOS", "run": "x", "mutation": {}}]"#,
            #"[{"id": "m", "os": "macOS", "mutation": {"budget": 0}}]"#,
            #"[{"id": "m", "os": "macOS", "mutation": {"paths": [""]}}]"#
        ]
        for commands in refused {
            #expect(throws: SwiftCIError.self, "\(commands)") {
                _ = try Planner(configuration: configuration("{\"commands\":\(commands)}"), project: package)
                    .plan(event: Event(trigger: .nightly, ref: ""), changedFiles: nil)
            }
        }
        for commands in [
            #"[{"id": "m", "os": "macOS", "mutation": {"workspace": "persistent"}}]"#,
            #"[{"id": "m", "os": "macOS", "mutation": {"path": []}}]"#
        ] {
            #expect(throws: SwiftCIError.self, "\(commands)") { try configuration("{\"commands\":\(commands)}") }
        }
        let fine = try configuration(Self.json)
        _ = try Planner(configuration: fine, project: package)
            .plan(event: Event(trigger: .nightly, ref: ""), changedFiles: nil)
    }

    @Test func `a mutation command is planned only on its cadence, as a macOS job`() throws {
        let planner = Planner(configuration: try configuration(Self.json), project: package)
        let nightly = try planner.plan(event: Event(trigger: .nightly, ref: ""), changedFiles: nil)
        let push = try planner.plan(event: Event(trigger: .push, ref: "refs/heads/main"), changedFiles: nil)
        #expect(nightly.macOS.map(\.id).contains("mutation"))
        #expect(!nightly.linux.map(\.id).contains("mutation"))
        #expect(!(push.macOS + push.linux).map(\.id).contains("mutation"))
    }
}
