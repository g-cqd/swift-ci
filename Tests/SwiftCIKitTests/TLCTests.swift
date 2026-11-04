import Foundation
import SwiftCIKit
import Testing

struct TLCTests {
    @Test func `each cfg is a model of its module, and a buggy one is a control that must be refuted`() {
        let models = TLC.models(["B.tla", "B.cfg", "A.buggy.cfg", "A.cfg", "A.tla", "README.md"])
        // In file name order: a control before its twin.
        #expect(models.map(\.name) == ["A.buggy", "A", "B"])
        #expect(models.map(\.module) == ["A", "A", "B"])
        #expect(models.map(\.mustFail) == [true, false, false])
        // A state directory per run, named by the caller: never TLC's per-second one beside the model.
        #expect(
            TLC.arguments(java: "java", jar: "/c/tla2tools.jar", model: models[0], states: "/tmp/s/A.buggy")
                == [
                    "java", "-XX:+UseParallelGC", "-cp", "/c/tla2tools.jar", "tlc2.TLC", "-config", "A.buggy.cfg",
                    "-metadir", "/tmp/s/A.buggy", "-workers", "auto", "-cleanup", "A.tla"
                ]
        )
    }

    @Test func `Java is JAVA_HOME's, then the path's, then Homebrew's keg-only openjdk`() {
        #expect(TLC.javaCandidates(javaHome: "/jdk").prefix(2) == ["/jdk/bin/java", "java"])
        #expect(TLC.javaCandidates(javaHome: nil).first == "java")
        #expect(TLC.javaCandidates(javaHome: nil).contains("/opt/homebrew/opt/openjdk/bin/java"))
    }

    /// Outputs and exit statuses as TLC 1.7.4 gives them.
    @Test func `the verdict is read from TLC's error line, not only its exit status`() {
        let held =
            "Progress(2): 232,263 states generated (232,263 s/min), 213,260 distinct states found (213,260 ds/min)\n"
            + "Model checking completed. No error has been found.\n49188 states generated, 19682 distinct states found, 0 states left on queue.\n"
        let invariant = "Error: Invariant SnapshotIsReference is violated.\nError: The behavior up to this point is:\n"
        // An invariant false in the initial state: exit status 151, and no "is violated".
        let initial = "Starting...\nError: The invariant of ResyncIsFreshParse is equal to FALSE\nFinished in 00s\n"
        let deadlock = "Error: Deadlock reached.\n"
        let parse = "Error: Parsing or semantic analysis failed. Module-Table lookup failure for module name Broken\n"
        let collision =
            "Exception in thread \"main\" util.Assert$TLCRuntimeException: TLC writes its files to a directory whose name is generated from the current time.\n"

        #expect(
            TLC.verdict(mustFail: false, status: 0, output: held)
                == .held("49188 states generated, 19682 distinct states found, 0 states left on queue.")
        )
        #expect(
            TLC.verdict(mustFail: false, status: 12, output: invariant)
                == .failed("Error: Invariant SnapshotIsReference is violated.")
        )
        #expect(
            TLC.verdict(mustFail: true, status: 12, output: invariant)
                == .refutedAsItMust("Error: Invariant SnapshotIsReference is violated.")
        )
        #expect(TLC.verdict(mustFail: true, status: 151, output: initial).passed)
        #expect(TLC.verdict(mustFail: true, status: 11, output: deadlock).passed)
        #expect(!TLC.verdict(mustFail: true, status: 0, output: held).passed)
        // A run that failed for another reason is neither a refutation nor a pass.
        #expect(!TLC.verdict(mustFail: true, status: 150, output: parse).passed)
        #expect(!TLC.verdict(mustFail: true, status: 1, output: collision).passed)
        #expect(
            TLC.verdict(mustFail: false, status: 150, output: parse)
                == .failed("TLC failed (exit status 150): \(parse.dropLast())")
        )
    }

    @Test func `a command checks TLA+ models instead of running a shell command, and needs exactly one of them`() throws
    {
        let json =
            #"{"commands": [{"id": "tla-models", "title": "Verification · TLA+ Models", "tla": {"models": "docs/formal"}, "after": "macos-debug"}]}"#
        let planner = StepPlanner(configuration: try configuration(json), project: package, lock: .builtIn)
        let steps = try planner.steps(for: CheckID.macOSDebug)
        #expect(steps.last == .tla(title: "Verification · TLA+ Models", models: TLAModels(models: "docs/formal")))
        #expect(
            try configuration(#"{"commands": [{"id": "t", "tla": {}}]}"#).commands.first?.tla?.models == "docs/formal"
        )
        #expect(throws: SwiftCIError.self) { try configuration(#"{"commands": [{"id": "t", "tla": {"model": "x"}}]}"#) }
        for commands in [#"[{"id": "t", "run": "x", "tla": {}}]"#, #"[{"id": "t"}]"#] {
            #expect(throws: SwiftCIError.self) {
                _ = try Planner(configuration: configuration("{\"commands\":\(commands)}"), project: package)
                    .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
            }
        }
    }
}
