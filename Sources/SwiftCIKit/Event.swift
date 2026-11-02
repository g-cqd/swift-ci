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

/// An error worth showing as it is.
public struct SwiftCIError: Error, Equatable, CustomStringConvertible, Sendable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}
