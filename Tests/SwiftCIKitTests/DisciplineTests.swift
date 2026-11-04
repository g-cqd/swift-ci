import Foundation
import SwiftCIKit
import Testing

struct DisciplineTests {
    @Test func `each rule finds its pattern where it applies, and lint:allow exempts a line`() throws {
        let sandbox = try Sandbox([
            "Sources/Lib/a.swift": "let x = strtod(s, nil)\nlet y = strtod(s, nil) // lint:allow\n",
            "Tests/T/t.swift": """
            struct SplitMix64 {}
            #expect(throws: (any Error).self) { try f() }
            #expect(ContinuousClock.now - start < .seconds(1))
            let fine = ContinuousClock.now
            """,
            // strtod in tests and test rules in sources are not findings.
            "Tests/T/u.swift": "let z = strtod(s, nil)\n",
            "Sources/Lib/b.swift": "struct SplitMix64 {}\n"
        ])
        let findings = Discipline().scan(root: sandbox.root)
        #expect(
            findings.map { "\($0.path):\($0.line):\($0.rule.rawValue)" } == [
                "Sources/Lib/a.swift:1:strtod", "Tests/T/t.swift:1:inline-prng", "Tests/T/t.swift:2:untyped-throws",
                "Tests/T/t.swift:3:wall-clock"
            ]
        )
        var some = Discipline()
        some.rules = [.wallClock]
        #expect(some.scan(root: sandbox.root).map(\.rule) == [.wallClock])
    }

    @Test func `only the shipped targets are scanned for strtod`() throws {
        let sandbox = try Sandbox(["Sources/Tool/m.swift": "strtod(a, b)\n", "Sources/Lib/l.swift": "strtod(a, b)\n"])
        var discipline = Discipline()
        discipline.shipped = ["Sources/Lib"]
        #expect(discipline.scan(root: sandbox.root).map(\.path) == ["Sources/Lib/l.swift"])
    }

    @Test func `the strict configuration adds the force-unwrap rules to the project's own`() throws {
        let base = Data(#"{"version": 1, "lineLength": 120, "rules": {"OrderedImports": true}}"#.utf8)
        let strict = try JSONSerialization.jsonObject(with: try Discipline.strictConfiguration(from: base))
        let rules = try #require((strict as? [String: Any])?["rules"] as? [String: Bool])
        #expect(rules == ["OrderedImports": true, "NeverForceUnwrap": true, "NeverUseForceTry": true])
        #expect((strict as? [String: Any])?["lineLength"] as? Int == 120)
        #expect(throws: SwiftCIError.self) { try Discipline.strictConfiguration(from: Data("[]".utf8)) }
    }

    @Test func `quality runs discipline after the formatters when it is configured, and only then`() throws {
        let json = #"{"quality": {"analyzers": [], "discipline": {"shipped": ["Sources/Lib"]}}}"#
        let planner = StepPlanner(configuration: try configuration(json), project: package, lock: .builtIn)
        let lines = commandLines(try planner.steps(for: CheckID.quality, swiftFiles: ["Sources/Lib/a.swift"]))
        #expect(lines.last == "discipline Sources/Lib")
        let decoded = try configuration(json).quality.discipline
        #expect(decoded?.forceUnwrap == true && decoded?.rules == Discipline.Rule.allCases)
        let off = StepPlanner(configuration: Configuration(), project: package, lock: .builtIn)
        #expect(!commandLines(try off.steps(for: CheckID.quality)).contains { $0.hasPrefix("discipline") })
        #expect(throws: SwiftCIError.self) { try configuration(#"{"quality": {"discipline": {"rules": ["nope"]}}}"#) }
        #expect(throws: SwiftCIError.self) { try configuration(#"{"quality": {"discipline": {"shiped": []}}}"#) }
    }

    @Test func `a force unwrap in shipped code fails the step and one in the tests does not`() throws {
        let format = #"{"version": 1, "rules": {}}"#
        let clean = try Sandbox([
            ".swift-format": format, "Sources/Lib/a.swift": "let a: Int? = 1\nlet b = a ?? 0\n",
            "Tests/T/t.swift": "let c = Int(\"1\")!\n"
        ])
        var discipline = Discipline()
        discipline.shipped = ["Sources/Lib"]
        var executor = Executor(root: clean.root)
        try executor.run([.discipline(discipline)])
        let unsafe = try Sandbox([".swift-format": format, "Sources/Lib/a.swift": "let c = Int(\"1\")!\n"])
        var failing = Executor(root: unsafe.root)
        #expect(throws: SwiftCIError.self) { try failing.run([.discipline(discipline)]) }
    }

    @Test func `only the force-unwrap rules' diagnostics count, and a linter failure without any is reported`() {
        let spacing = "Sources/Lib/a.swift:40:17: error: [Spacing] remove 1 space"
        let unwrap = "Sources/Lib/a.swift:2:9: error: [NeverForceUnwrap] do not force unwrap 'x'"
        let tryBang = "Sources/Lib/a.swift:3:9: error: [NeverUseForceTry] do not use force try"
        #expect(Discipline.forceUnwrapVerdict(status: 0, output: "") == .clean)
        #expect(Discipline.forceUnwrapVerdict(status: 1, output: spacing + "\n") == .clean)
        #expect(
            Discipline.forceUnwrapVerdict(status: 1, output: [spacing, unwrap, tryBang].joined(separator: "\n"))
                == .findings([unwrap, tryBang])
        )
        #expect(Discipline.forceUnwrapVerdict(status: 1, output: "Segmentation fault\n") == .failed("exit status 1"))
    }

    @Test func `a formatting problem in shipped code is not a force unwrap, and the count says what failed`() throws {
        let format = #"{"version": 1, "rules": {}}"#
        var discipline = Discipline()
        discipline.shipped = ["Sources/Lib"]
        let badlyFormatted = try Sandbox([
            ".swift-format": format,
            "Sources/Lib/a.swift": "enum Injected {  static   func  f(_ a: Int) -> Int {  return   a  }  }\n"
        ])
        var formatting = Executor(root: badlyFormatted.root)
        try formatting.run([.discipline(discipline)])
        let both = try Sandbox([
            ".swift-format": format, "Sources/Lib/a.swift": "let c = Int(\"1\")!\nenum E {  static   func  f() {}  }\n",
            "Sources/Lib/b.swift": "let d = strtod(s, nil)\n"
        ])
        var failing = Executor(root: both.root)
        let error = try #require(throws: SwiftCIError.self) { try failing.run([.discipline(discipline)]) }
        #expect(error.description.contains("1 textual finding(s), 1 force unwrap(s) or try! in shipped code"))
    }
}
