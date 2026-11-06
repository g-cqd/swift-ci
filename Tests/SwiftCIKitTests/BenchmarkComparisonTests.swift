import Foundation
import SwiftCIKit
import Testing

@testable import SwiftCIKit

struct BenchmarkComparisonTests {
    @Test func `a benchmark command is decoded with its defaults and planned as a job of its own`() throws {
        let json = #"""
            {"commands": [{"id": "bench", "os": "macOS", "cadence": ["push", "nightly"],
              "benchmark": {"filter": "toml/.*", "shared": [".build/fixtures"]}, "paths": ["Sources/**"]}]}
            """#
        let command = try configuration(json).commands[0]
        #expect(command.benchmark == BenchmarkComparison(filter: "toml/.*", shared: [".build/fixtures"]))
        #expect(command.benchmark?.package == "Benchmarks")
        #expect(command.benchmark?.metrics == ["instructions", "mallocCountTotal"])
        let planner = StepPlanner(configuration: try configuration(json), project: package, lock: .builtIn)
        #expect(commandLines(try planner.steps(for: "bench")) == ["benchmark Benchmarks"])
    }

    @Test func `a push runs a command with paths only when it touched one; other runs always do`() throws {
        let json = #"""
            {"commands": [{"id": "bench", "os": "macOS", "cadence": ["push", "nightly"], "benchmark": {},
              "paths": ["Sources/**", "Benchmarks/**"]}]}
            """#
        let planner = Planner(configuration: try configuration(json), project: package)
        func planned(_ trigger: Trigger, _ files: [String]?) throws -> Bool {
            try planner.plan(event: Event(trigger: trigger, ref: "refs/heads/main"), changedFiles: files).macOS
                .contains { $0.id == "bench" }
        }
        #expect(try planned(.push, ["Sources/A/B.swift"]))
        #expect(try planned(.push, ["Benchmarks/Package.swift", "README.md"]))
        #expect(try !planned(.push, ["Tests/A/B.swift"]))
        #expect(try planned(.push, nil))
        #expect(try planned(.nightly, ["Tests/A/B.swift"]))
    }

    @Test func `a benchmark command is refused attached to a check, with another action, or with a bad field`() throws {
        let refused = [
            #"[{"id": "b", "os": "macOS", "after": "macos-debug", "benchmark": {}}]"#,
            #"[{"id": "b", "os": "macOS", "before": ["macos-debug"], "benchmark": {}}]"#,
            #"[{"id": "b", "os": "macOS", "run": "x", "benchmark": {}}]"#,
            #"[{"id": "b", "os": "macOS", "benchmark": {"package": "../x"}}]"#,
            #"[{"id": "b", "os": "macOS", "benchmark": {"metrics": []}}]"#,
            #"[{"id": "b", "os": "macOS", "benchmark": {"shared": ["/etc"]}}]"#,
            #"[{"id": "b", "run": "x", "after": "linux-debug", "paths": ["Sources/**"]}]"#
        ]
        for commands in refused {
            #expect(throws: SwiftCIError.self, "\(commands)") {
                _ = try Planner(configuration: configuration("{\"commands\":\(commands)}"), project: package)
                    .plan(event: Event(trigger: .nightly, ref: ""), changedFiles: nil)
            }
        }
        #expect(throws: SwiftCIError.self) {
            try configuration(#"{"commands": [{"id": "b", "os": "macOS", "benchmark": {"filters": "x"}}]}"#)
        }
    }

    @Test func `the commit before is the run's base, or HEAD^ for a run without one or a new branch`() {
        #expect(BenchmarkComparison.base(from: "abc123") == "abc123")
        #expect(BenchmarkComparison.base(from: nil) == "HEAD^")
        #expect(BenchmarkComparison.base(from: "") == "HEAD^")
        #expect(BenchmarkComparison.base(from: String(repeating: "0", count: 40)) == "HEAD^")
    }

    @Test func `the runs store the chosen metrics under a name, and the comparisons name both baselines`() {
        let comparison = BenchmarkComparison(package: "Bench", filter: "yaml/.*", metrics: ["instructions"])
        #expect(
            comparison.recordArguments("base") == [
                "swift", "package", "--package-path", "Bench", "--allow-writing-to-package-directory", "benchmark",
                "baseline", "update", "base", "--no-progress", "--filter", "yaml/.*", "--metric", "instructions"
            ]
        )
        #expect(
            comparison.comparisonArguments("check", base: "base", head: "head") == [
                "swift", "package", "--package-path", "Bench", "benchmark", "baseline", "check", "base", "head",
                "--no-progress"
            ]
        )
        #expect(
            comparison.comparisonArguments("compare", base: "b", head: "h", markdown: true).suffix(2) == [
                "--format", "markdown"
            ]
        )
    }

    @Test func `the verdict reads the plugin's message: equal, improved and regressed, or a failure with its end`() {
        #expect(BenchmarkComparison.verdict(status: 0, output: "") == .equal)
        #expect(BenchmarkComparison.verdict(status: 1, output: "error: benchmarkThresholdImprovement") == .improved)
        #expect(BenchmarkComparison.verdict(status: 1, output: "error: benchmarkThresholdRegression") == .regressed)
        let failed = BenchmarkComparison.verdict(status: 1, output: "one\nerror: baselineNotFound")
        #expect(failed == .failed("baseline check exited with 1: one\nerror: baselineNotFound"))
        #expect(
            !failed.passed && BenchmarkComparison.Verdict.improved.passed
                && !BenchmarkComparison.Verdict.regressed.passed
        )
    }
}
