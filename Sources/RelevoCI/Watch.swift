import Foundation

public enum Event: Sendable, Equatable {
    case checksFailed(PullRequest, [Check])
    case feedback(PullRequest, [Feedback])
    case conflict(PullRequest)
}

public struct Watch: Sendable {
    public let viewer: String
    public let ignoredAuthors: Set<String>
    public let trustedAuthors: Set<String>
    private var primedFor: Int?
    private var seenFeedback: Set<String> = []
    private var reportedFailures: Set<String> = []
    private var reportedConflicts: Set<String> = []

    public init(viewer: String, ignoredAuthors: Set<String> = [], trustedAuthors: Set<String> = []) {
        self.viewer = viewer.lowercased()
        self.ignoredAuthors = Set(ignoredAuthors.map { $0.lowercased() })
        self.trustedAuthors = Set(trustedAuthors.map { $0.lowercased() })
    }

    public mutating func events(for pullRequest: PullRequest?) -> [Event] {
        guard let pullRequest, pullRequest.isOpen else { return [] }
        if primedFor != pullRequest.number {
            primedFor = pullRequest.number
            seenFeedback = Set(pullRequest.feedback.map(\.id))
            reportedFailures = []
            reportedConflicts = []
        }

        var events: [Event] = []
        let failed = pullRequest.checks.filter { $0.outcome == .failed }
        let finished = !pullRequest.checks.contains { $0.outcome == .pending }
        if finished, !failed.isEmpty, reportedFailures.insert(pullRequest.headSha).inserted {
            events.append(.checksFailed(pullRequest, failed))
        }
        if pullRequest.hasConflicts, reportedConflicts.insert(pullRequest.headSha).inserted {
            events.append(.conflict(pullRequest))
        }
        let fresh = pullRequest.feedback.filter { !seenFeedback.contains($0.id) && shouldForward($0) }
        seenFeedback.formUnion(pullRequest.feedback.map(\.id))
        if !fresh.isEmpty {
            events.append(.feedback(pullRequest, fresh))
        }
        return events
    }

    private func shouldForward(_ item: Feedback) -> Bool {
        let author = item.author.lowercased()
        guard author != viewer, !ignoredAuthors.contains(author) else { return false }
        return item.isFromCollaborator || trustedAuthors.contains(author)
    }
}
