/// The built-in checks. A configuration's `checks` overrides their cadence; `commands` add its own.
public enum CheckID {
    /// Formatters, linters and the g-cqd analyzers, on Linux: they read source and need no build.
    public static let quality = "quality"
    public static let linuxDebug = "linux-debug"
    public static let linuxRelease = "linux-release"
    public static let linuxAddress = "linux-address"
    public static let linuxThread = "linux-thread"
    /// The macOS tests, with coverage.
    public static let macOSDebug = "macos-debug"
    public static let macOSRelease = "macos-release"
    public static let macOSAddress = "macos-address"
    public static let macOSThread = "macos-thread"
    /// A build and test with none of `swift.environment`: what a consumer of the package gets.
    public static let consumer = "consumer"
    /// Every `platforms` entry, one after the other on one runner.
    public static let platforms = "platforms"
    public static let documentation = "documentation"
    /// The release archives of `release.executables`, one per OS.
    public static let archiveLinux = "archive-linux"
    public static let archiveMacOS = "archive-macos"
}

/// A built-in check: where it runs, when by default, and for which projects.
struct Check: Sendable {
    let id: String
    let os: OS
    let cadence: Set<Trigger>
    let applies: @Sendable (Project, Configuration) -> Bool

    static let catalog: [Check] = [
        Check(id: CheckID.quality, os: .linux, cadence: Trigger.everyChange) { _, _ in true },
        Check(id: CheckID.linuxDebug, os: .linux, cadence: Trigger.everyChange) { project, _ in project.linux },
        Check(id: CheckID.linuxRelease, os: .linux, cadence: Trigger.everyChange) { project, _ in project.linux },
        Check(id: CheckID.linuxAddress, os: .linux, cadence: Trigger.everyChange) { project, _ in project.linux },
        Check(id: CheckID.linuxThread, os: .linux, cadence: Trigger.heavy) { project, _ in project.linux },
        Check(id: CheckID.consumer, os: .linux, cadence: Trigger.everyChange) { project, configuration in
            project.linux && !configuration.swift.environment.isEmpty
        },
        Check(id: CheckID.macOSDebug, os: .macOS, cadence: Trigger.everyChange) { _, _ in true },
        Check(id: CheckID.macOSRelease, os: .macOS, cadence: Trigger.heavy) { _, _ in true },
        Check(id: CheckID.macOSAddress, os: .macOS, cadence: Trigger.heavy) { _, _ in true },
        Check(id: CheckID.macOSThread, os: .macOS, cadence: Trigger.heavy) { _, _ in true },
        Check(id: CheckID.platforms, os: .macOS, cadence: Trigger.heavy) { _, configuration in
            !configuration.platforms.isEmpty
        },
        Check(id: CheckID.documentation, os: .macOS, cadence: Trigger.heavy) { _, configuration in
            configuration.documentation != nil
        },
        Check(id: CheckID.archiveLinux, os: .linux, cadence: [.tag, .dispatch]) { project, configuration in
            project.linux && !(configuration.release?.executables.isEmpty ?? true)
        },
        Check(id: CheckID.archiveMacOS, os: .macOS, cadence: [.tag, .dispatch]) { _, configuration in
            !(configuration.release?.executables.isEmpty ?? true)
        }
    ]
}

/// One job of a plan: a check on one runner with one toolchain. The workflow turns each into a matrix entry and runs
/// `swift-ci run <id> --swift <swift>` in it.
public struct PlannedJob: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var os: OS
    /// Runner labels.
    public var runner: [String]
    /// The Linux image; empty on macOS.
    public var container: String
    /// The Swift version, or `xcode` for the selected Xcode's toolchain.
    public var swift: String
    /// macOS: install `swift` before the job (it is not the selected Xcode's).
    public var installSwift: Bool
    /// macOS: the Xcode to select; empty keeps the runner's.
    public var xcode: String
    /// A failure is reported but does not fail the run.
    public var advisory: Bool
    /// The prefix of the job's SwiftPM cache key: one per check, OS and toolchain.
    public var cache: String
}

/// What a run does, decided once by the `plan` job.
public struct Plan: Codable, Sendable, Equatable {
    public var trigger: Trigger
    public var linux: [PlannedJob]
    public var macOS: [PlannedJob]
    /// Jobs whose failure is reported but fails nothing (an advisory toolchain), on either OS. The gate does not wait
    /// for them.
    public var advisory: [PlannedJob]
    /// Publish a release (a tag of a project with executables).
    public var publish: Bool
    /// Why the run checks nothing, when it does not.
    public var skipped: String?
}

/// Decides the jobs of a run from the configuration, the project and the event.
public struct Planner: Sendable {
    public var configuration: Configuration
    public var project: Project

    public init(configuration: Configuration, project: Project) {
        self.configuration = configuration
        self.project = project
    }

    /// The cadence of `check` after the configuration's override.
    func cadence(of check: Check) -> Set<Trigger> {
        configuration.checks[check.id].map(Set.init) ?? check.cadence
    }

    /// The plan for `event`.
    /// - Parameters:
    ///   - event: what started the run.
    ///   - changedFiles: the files the change touched; nil when unknown (never skipped then).
    ///   - hoursSinceLastCommit: for the nightly run, the age of the newest commit; nil when unknown.
    /// - Returns: the jobs per OS, whether to publish, or why nothing runs.
    /// - Throws: ``SwiftCIError`` for settings that name no check or clash.
    public func plan(event: Event, changedFiles: [String]?, hoursSinceLastCommit: Double? = nil) throws -> Plan {
        try validate()
        var plan = Plan(trigger: event.trigger, linux: [], macOS: [], advisory: [], publish: false, skipped: nil)
        if [.push, .pullRequest, .mergeQueue].contains(event.trigger), let files = changedFiles, !files.isEmpty {
            let documentation = configuration.documentationOnlyPaths.map(Glob.init)
            if files.allSatisfy({ file in documentation.contains { $0.matches(file) } }) {
                plan.skipped = "only documentation changed (\(files.count) file\(files.count == 1 ? "" : "s"))"
                return plan
            }
        }
        if event.trigger == .nightly, let hours = hoursSinceLastCommit, hours > 24 {
            plan.skipped = "no commit since the previous nightly run (newest is \(Int(hours)) h old)"
            return plan
        }

        let checks = Check.catalog.filter {
            $0.applies(project, configuration) && cadence(of: $0).contains(event.trigger)
        }
        let commands = configuration.commands.filter { $0.cadence.contains(event.trigger) }
        for (id, os) in checks.map({ ($0.id, $0.os) }) + commands.map({ ($0.id, $0.os) }) {
            let planned = jobs(for: id, os: os)
            plan.advisory += planned.filter(\.advisory)
            if os == .linux {
                plan.linux += planned.filter { !$0.advisory }
            } else {
                plan.macOS += planned.filter { !$0.advisory }
            }
        }
        plan.publish = event.trigger == .tag && !(configuration.release?.executables.isEmpty ?? true)
        return plan
    }

    /// The jobs of one check: one per Swift version when the check is in `swift.matrix`, else on the primary one.
    func jobs(for id: String, os: OS) -> [PlannedJob] {
        let swift = configuration.swift
        let primary = swift.versions[0]
        var versions = [(version: primary, advisory: false)]
        if swift.matrix.contains(id) {
            versions = swift.versions.map { ($0, false) } + swift.advisory.map { ($0, true) }
        }
        return versions.map { entry in
            let version: String
            var install = false
            switch os {
                case .linux:
                    version = entry.version
                case .macOS:
                    if swift.matrix.contains(id) {
                        version = entry.version
                        install = true
                    } else if let macOS = swift.macOSVersion {
                        version = macOS
                        install = true
                    } else {
                        version = "xcode"
                    }
            }
            let suffix = version == "xcode" ? " · Xcode toolchain" : " · Swift \(version)"
            return PlannedJob(
                id: id,
                title: id + suffix,
                os: os,
                runner: os == .linux ? configuration.runners.linux : configuration.runners.macOS,
                container: os == .linux ? swift.image(for: version) : "",
                swift: version,
                installSwift: install,
                xcode: os == .macOS ? (swift.xcode ?? "") : "",
                advisory: entry.advisory,
                cache: "swift-ci-\(os.rawValue)-\(id)-\(version)"
            )
        }
    }

    /// Settings that cannot work together.
    func validate() throws {
        let known = Set(Check.catalog.map(\.id))
        for id in configuration.checks.keys where !known.contains(id) {
            throw SwiftCIError("checks.\(id): no such check (known: \(known.sorted().joined(separator: ", ")))")
        }
        for id in configuration.swift.matrix
        where !known.contains(id) && !configuration.commands.contains(where: { $0.id == id }) {
            throw SwiftCIError("swift.matrix: no check or command '\(id)'")
        }
        var seen = known
        for command in configuration.commands where !seen.insert(command.id).inserted {
            throw SwiftCIError("commands: id '\(command.id)' is used twice or names a built-in check")
        }
    }
}
