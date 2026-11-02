public import Foundation

/// What started a run. Every check of a configuration says on which of these it runs (its cadence).
public enum Trigger: String, Codable, Sendable, CaseIterable, Comparable {
    /// A push to a branch.
    case push
    /// A pull request opened, reopened or updated.
    case pullRequest = "pull-request"
    /// A merge queue asking for checks.
    case mergeQueue = "merge-queue"
    /// The scheduled run. It does nothing when no commit landed since the previous one (``Planner``).
    case nightly
    /// A pushed tag: the full set, then the release.
    case tag
    /// A manual run.
    case dispatch

    /// The triggers a change is checked on: every push, pull request, merge queue, tag and manual run.
    public static let everyChange: Set<Trigger> = [.push, .pullRequest, .mergeQueue, .tag, .dispatch]
    /// The triggers of the heavy checks: the nightly run, a tag and a manual run.
    public static let heavy: Set<Trigger> = [.nightly, .tag, .dispatch]

    public static func < (lhs: Trigger, rhs: Trigger) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A run's event, as GitHub Actions describes it.
public struct Event: Sendable, Equatable {
    public var trigger: Trigger
    /// The full ref (`refs/heads/main`, `refs/tags/v1.2.0`, `refs/pull/7/merge`).
    public var ref: String

    public init(trigger: Trigger, ref: String) {
        self.trigger = trigger
        self.ref = ref
    }

    /// The tag's name for a tag, else nil.
    public var tagName: String? {
        ref.hasPrefix("refs/tags/") ? String(ref.dropFirst("refs/tags/".count)) : nil
    }

    /// The event GitHub names `eventName` (`GITHUB_EVENT_NAME`) for `ref` (`GITHUB_REF`).
    public static func gitHub(eventName: String, ref: String) throws(SwiftCIError) -> Event {
        let trigger: Trigger
        switch eventName {
            case "push": trigger = ref.hasPrefix("refs/tags/") ? .tag : .push
            case "pull_request", "pull_request_target": trigger = .pullRequest
            case "merge_group": trigger = .mergeQueue
            case "schedule": trigger = .nightly
            case "workflow_dispatch", "repository_dispatch": trigger = .dispatch
            default: throw SwiftCIError("unsupported event '\(eventName)'")
        }
        return Event(trigger: trigger, ref: ref)
    }
}

extension Event {
    /// The event named `name`: a GitHub event name (`push`, `pull_request`, `schedule`…), or, from any other CI, a
    /// trigger (`push`, `pull-request`, `merge-queue`, `nightly`, `tag`, `dispatch`). For `tag`, `ref` may be the tag's
    /// name.
    public static func named(_ name: String, ref: String) throws(SwiftCIError) -> Event {
        if let event = try? gitHub(eventName: name, ref: ref) { return event }
        guard let trigger = Trigger(rawValue: name) else {
            let triggers = Trigger.allCases.map(\.rawValue).joined(separator: ", ")
            throw SwiftCIError("unknown event '\(name)': a GitHub event name, or one of \(triggers)")
        }
        let full = trigger == .tag && !ref.hasPrefix("refs/") ? "refs/tags/\(ref)" : ref
        return Event(trigger: trigger, ref: full)
    }
}

/// What a GitHub Actions job knows of its run, from its environment and event payload, so the CLI needs no
/// arguments there.
public struct GitHubContext: Sendable, Equatable {
    public var eventName: String?
    public var ref: String?
    /// The tag of a tag run.
    public var tag: String?
    /// What a change is compared with: the previous head of a push, the base of a pull request or of a queue.
    public var base: String?

    public init(environment: [String: String], payload: Data?) {
        eventName = environment["GITHUB_EVENT_NAME"]
        ref = environment["GITHUB_REF"]
        tag = environment["GITHUB_REF_TYPE"] == "tag" ? environment["GITHUB_REF_NAME"] : nil
        base = payload.flatMap(Self.base(inPayload:))
    }

    /// The current process's.
    public static var current: GitHubContext {
        let environment = ProcessInfo.processInfo.environment
        let payload = environment["GITHUB_EVENT_PATH"].flatMap { FileManager.default.contents(atPath: $0) }
        return GitHubContext(environment: environment, payload: payload)
    }

    /// `before` (push), `pull_request.base.sha`, `merge_group.base_sha`; nil for another event or a new branch.
    static func base(inPayload data: Data) -> String? {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let pullRequest = (event["pull_request"] as? [String: Any])?["base"] as? [String: Any]
        let candidates = [event["before"], pullRequest?["sha"], (event["merge_group"] as? [String: Any])?["base_sha"]]
        return candidates.compactMap { $0 as? String }.first { !$0.isEmpty && !$0.allSatisfy { $0 == "0" } }
    }
}

/// An error worth showing as it is.
public struct SwiftCIError: Error, Equatable, CustomStringConvertible, Sendable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}
