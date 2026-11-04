import Foundation
import SwiftCIKit
import Testing

struct PlannerTests {
    func plan(
        _ json: String = "{}",
        project: Project = package,
        _ trigger: Trigger,
        ref: String = "refs/heads/main",
        files: [String]? = ["Sources/A/a.swift"],
        hours: Double? = nil
    ) throws -> Plan {
        try Planner(configuration: try configuration(json), project: project)
            .plan(event: Event(trigger: trigger, ref: ref), changedFiles: files, hoursSinceLastCommit: hours)
    }

    func plan(_ trigger: Trigger, files: [String]? = ["Sources/A/a.swift"], hours: Double? = nil) throws -> Plan {
        try plan("{}", trigger, files: files, hours: hours)
    }

    func ids(_ jobs: [PlannedJob]) -> [String] { jobs.map(\.id) }

    @Test func `weekly and unconditional schedules have a configurable idle window`() throws {
        let weekly = #"{"scheduledMaxCommitAgeHours":168}"#
        #expect(try plan(weekly, .nightly, hours: 120).skipped == nil)
        #expect(try plan(weekly, .nightly, hours: 168).skipped == nil)
        #expect(try plan(weekly, .nightly, hours: 169).skipped != nil)
        #expect(try plan(#"{"scheduledMaxCommitAgeHours":null}"#, .nightly, hours: 1000).skipped == nil)
        #expect(throws: SwiftCIError.self) {
            try configuration(#"{"scheduledMaxCommitAgeHours":-1}"#)
        }
    }

    @Test func `a push checks quality and Linux on every change, and macOS debug once`() throws {
        let plan = try plan(.push)
        #expect(ids(plan.linux) == [CheckID.quality, CheckID.linuxDebug, CheckID.linuxRelease, CheckID.linuxAddress])
        #expect(ids(plan.macOS) == [CheckID.macOSDebug])
        #expect(!plan.publish)
        #expect(plan.skipped == nil)
        let macOS = try #require(plan.macOS.first)
        #expect(macOS.runner == ["macos-26"])
        #expect(macOS.installSwift)
        #expect(macOS.swift == "6.4.1")
        #expect(macOS.container.isEmpty)
        #expect(plan.linux[1].container == "swift:6.4.1-noble")
        #expect(plan.linux[1].cache == "swift-ci-linux-linux-debug-6.4.1")
    }

    @Test func `the nightly run takes the heavy checks, and nothing without a new commit`() throws {
        let nightly = try plan(.nightly, files: nil, hours: 3)
        #expect(ids(nightly.linux) == [CheckID.linuxThread])
        #expect(ids(nightly.macOS) == [CheckID.macOSRelease, CheckID.macOSAddress, CheckID.macOSThread])
        let idle = try plan(.nightly, files: nil, hours: 30)
        #expect(idle.linux.isEmpty && idle.macOS.isEmpty)
        #expect(idle.skipped?.contains("no recent commit for the scheduled") == true)
    }

    @Test func `a tag runs everything, archives the executables and publishes`() throws {
        let json =
            #"{"release": {"executables": ["tool"]}, "platforms": [{"name": "iOS"}], "documentation": {"targets": ["Tool"]}}"#
        let tag = try plan(json, .tag, ref: "refs/tags/v1.0.0", files: nil)
        #expect(ids(tag.linux).contains(CheckID.archiveLinux))
        #expect(
            ids(tag.macOS) == [
                CheckID.macOSDebug, CheckID.macOSRelease, CheckID.macOSAddress, CheckID.macOSThread, CheckID.platforms,
                CheckID.documentation, CheckID.archiveMacOS
            ]
        )
        #expect(tag.publish)
        #expect(!(try plan(json, .push)).publish)
    }

    @Test func `a change to documentation only checks nothing, but a tag or a manual run always does`() throws {
        let files = ["README.md", "docs/guide.md", "development/adr/0001.md", "release-notes/v1.md"]
        let push = try plan(.push, files: files)
        #expect(push.linux.isEmpty && push.macOS.isEmpty)
        #expect(push.skipped == "only documentation changed (4 files)")
        #expect(try plan(.push, files: files + ["Sources/A/a.swift"]).skipped == nil)
        #expect(try plan(.dispatch, files: files).skipped == nil)
        #expect(try plan(.push, files: nil).skipped == nil)  // unknown changes are checked
        #expect(try plan(.push, files: []).skipped == nil)
    }

    @Test func `matrix checks run on every version, advisory ones without failing the run`() throws {
        let json =
            #"{"swift": {"versions": ["6.4.1", "6.3.3"], "advisory": ["nightly-main"], "matrix": ["linux-debug"]}}"#
        let push = try plan(json, .push)
        let debug = push.linux.filter { $0.id == CheckID.linuxDebug && !$0.advisory }
        #expect(debug.map(\.swift) == ["6.4.1", "6.3.3"])
        #expect(debug.map(\.container) == ["swift:6.4.1-noble", "swift:6.3.3-noble"])
        #expect(push.advisory.map(\.swift) == ["nightly-main"])
        #expect(push.advisory.map(\.container) == ["swiftlang/swift:nightly-main-noble"])
        // In the Linux matrix, marked: the workflow continues on its error, and names it.
        #expect(push.advisory.allSatisfy(\.advisory) && push.linux.filter(\.advisory) == push.advisory)
        #expect(push.advisory.map(\.title) == ["Tests · Debug · Linux · Swift nightly-main · Advisory"])
        #expect(!push.linux.filter { !$0.advisory }.contains { $0.title.hasSuffix("Advisory") })
        #expect(try plan(json, .push).linux.filter { $0.id == CheckID.linuxRelease }.map(\.swift) == ["6.4.1"])
    }

    @Test func `an Xcode project has no Linux build, and uses the selected Xcode when told`() throws {
        let xcode = Project(kind: .xcodeProject, xcode: "App.xcodeproj", linux: false, formatters: [], corpus: ["."])
        let plan = try plan(
            #"{"swift": {"macOS": "xcode", "xcode": "26.6"}, "runners": {"macOS": ["self-hosted", "mobile"]}}"#,
            project: xcode,
            .push
        )
        #expect(ids(plan.linux) == [CheckID.quality])
        #expect(ids(plan.macOS) == [CheckID.macOSDebug])
        let job = try #require(plan.macOS.first)
        #expect(job.swift == "xcode" && !job.installSwift && job.xcode == "26.6")
        #expect(job.runner == ["self-hosted", "mobile"])
    }

    @Test func `cadence overrides, the consumer check and commands`() throws {
        let json = #"""
            {"checks": {"linux-address": [], "macos-release": ["push"]},
             "swift": {"environment": {"DEV": "1"}},
             "commands": [{"id": "oracle", "run": "Scripts/oracle.sh"}, {"id": "leaks", "run": "x", "os": "macOS", "cadence": ["nightly"]}]}
            """#
        let push = try plan(json, .push)
        #expect(
            ids(push.linux) == [CheckID.quality, CheckID.linuxDebug, CheckID.linuxRelease, CheckID.consumer, "oracle"]
        )
        #expect(ids(push.macOS) == [CheckID.macOSDebug, CheckID.macOSRelease])
        #expect(ids(try plan(json, .nightly, files: nil, hours: 1).macOS).contains("leaks"))
    }

    @Test func `settings that name nothing are errors`() {
        #expect(throws: SwiftCIError.self) { try plan(#"{"checks": {"linux-debgu": []}}"#, .push) }
        #expect(throws: SwiftCIError.self) { try plan(#"{"swift": {"matrix": ["nothing"]}}"#, .push) }
        #expect(throws: SwiftCIError.self) { try plan(#"{"commands": [{"id": "quality", "run": "x"}]}"#, .push) }
        #expect(throws: SwiftCIError.self) {
            try plan(#"{"commands": [{"id": "a", "run": "x"}, {"id": "a", "run": "y"}]}"#, .push)
        }
    }
}

struct JobNamingTests {
    @Test func `built in job labels show purpose platform and toolchain without changing identity`() throws {
        let plan = try Planner(configuration: configuration("{}"), project: package)
            .plan(event: Event(trigger: .dispatch, ref: ""), changedFiles: nil)
        let jobs = plan.linux + plan.macOS
        #expect(jobs.first { $0.id == CheckID.linuxDebug }?.title == "Tests · Debug · Linux · Swift 6.4.1")
        #expect(jobs.first { $0.id == CheckID.macOSDebug }?.title == "Tests · Debug · macOS · Swift 6.4.1")
        #expect(jobs.first { $0.id == CheckID.linuxAddress }?.title == "Sanitizers · Address · Linux · Swift 6.4.1")
        #expect(jobs.first { $0.id == CheckID.linuxDebug }?.cache == "swift-ci-linux-linux-debug-6.4.1")
        #expect(CheckID.title(for: "custom") == "custom")
    }

    @Test func `custom commands have a display title independent of their stable id`() throws {
        let config = try configuration(
            #"{"commands":[{"id":"smoke","title":"Integration · Mutation Smoke","run":"true","os":"macOS"}]}"#
        )
        let plan = try Planner(configuration: config, project: package)
            .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
        #expect(plan.macOS.first { $0.id == "smoke" }?.title == "Integration · Mutation Smoke · macOS · Swift 6.4.1")
    }
}

extension JobNamingTests {
    @Test func `all built in checks have labels distinct from their configuration IDs`() {
        let ids = [
            CheckID.quality, CheckID.linuxDebug, CheckID.linuxRelease, CheckID.linuxAddress,
            CheckID.linuxThread, CheckID.macOSDebug, CheckID.macOSRelease, CheckID.macOSAddress,
            CheckID.macOSThread, CheckID.consumer, CheckID.platforms, CheckID.documentation,
            CheckID.archiveLinux, CheckID.archiveMacOS
        ]
        for id in ids { #expect(CheckID.title(for: id) != id) }
    }

    @Test func `attached command labels apply to steps without creating standalone jobs`() throws {
        let config = try configuration(
            #"{"commands":[{"id":"fixtures","title":"Fixtures · Fetch Corpora","run":"fetch","before":["linux-debug"]}]}"#
        )
        let steps = try StepPlanner(configuration: config, project: package, lock: .builtIn)
            .steps(for: CheckID.linuxDebug)
        #expect(steps.first?.title == "Fixtures · Fetch Corpora")
        let plan = try Planner(configuration: config, project: package)
            .plan(event: Event(trigger: .push, ref: ""), changedFiles: nil)
        #expect(!(plan.linux + plan.macOS).contains { $0.id == "fixtures" })
    }
}
