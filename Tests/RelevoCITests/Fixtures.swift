import Foundation
@testable import RelevoCI

let pullRequestResponse = Data("""
    {
      "number": 42,
      "title": "Retry flaky uploads",
      "url": "https://github.com/acme/widgets/pull/42",
      "state": "OPEN",
      "headRefName": "fix/uploads",
      "headRefOid": "0123456789abcdef0123456789abcdef01234567",
      "baseRefName": "main",
      "mergeable": "MERGEABLE",
      "statusCheckRollup": [
        {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "FAILURE",
         "detailsUrl": "https://github.com/acme/widgets/actions/runs/111/job/222", "workflowName": "CI"},
        {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS",
         "detailsUrl": "https://github.com/acme/widgets/actions/runs/111/job/223", "workflowName": "CI"},
        {"__typename": "CheckRun", "name": "label", "status": "COMPLETED", "conclusion": "SKIPPED",
         "detailsUrl": "https://github.com/acme/widgets/actions/runs/333", "workflowName": "Labels"},
        {"__typename": "CheckRun", "name": "e2e", "status": "IN_PROGRESS", "conclusion": "",
         "detailsUrl": "https://github.com/acme/widgets/actions/runs/444/job/555", "workflowName": "E2E"},
        {"__typename": "StatusContext", "context": "deploy/preview", "state": "ERROR",
         "targetUrl": "https://deploys.example.com/42"}
      ],
      "comments": [
        {"id": "IC_1", "author": {"login": "alice"}, "authorAssociation": "MEMBER", "body": "Can we log the retry count?",
         "url": "https://github.com/acme/widgets/pull/42#issuecomment-1", "isMinimized": false},
        {"id": "IC_2", "author": {"login": "spammer"}, "authorAssociation": "NONE", "body": "hidden", "url": null, "isMinimized": true},
        {"id": "IC_3", "author": null, "body": "from a deleted account", "url": null, "isMinimized": false}
      ],
      "reviews": [
        {"id": "PRR_1", "author": {"login": "bob"}, "authorAssociation": "COLLABORATOR", "body": "Uploads above 5 MB still fail.", "state": "CHANGES_REQUESTED"},
        {"id": "PRR_2", "author": {"login": "bob"}, "body": "", "state": "COMMENTED"},
        {"id": "PRR_3", "author": {"login": "carol"}, "body": "Looks good", "state": "APPROVED"}
      ]
    }
    """.utf8)

let inlineCommentsResponse = Data("""
    {"id":901,"login":"bob","association":"COLLABORATOR","body":"Use exponential backoff here.","path":"Sources/Upload.swift","line":17,"url":"https://github.com/acme/widgets/pull/42#discussion_r901"}
    {"id":902,"login":"alice","association":"CONTRIBUTOR","body":"Nit: rename.","path":"Sources/Upload.swift","line":null,"url":null}
    {"id":903,"login":null,"body":"ghost","path":null,"line":null,"url":null}
    """.utf8)

func makePullRequest(
    number: Int = 42,
    state: String = "OPEN",
    sha: String = "aaaaaaa1111",
    mergeable: String = "MERGEABLE",
    checks: [Check] = [],
    feedback: [Feedback] = []
) -> PullRequest {
    PullRequest(
        number: number, title: "Retry flaky uploads", url: "https://github.com/acme/widgets/pull/\(number)",
        state: state, headRef: "fix/uploads", headSha: sha, baseRef: "main", mergeable: mergeable,
        checks: checks, feedback: feedback
    )
}

let failingTest = Check(name: "test", outcome: .failed, link: "https://github.com/acme/widgets/actions/runs/111/job/222")
let passingLint = Check(name: "lint", outcome: .passed, link: nil)
let pendingE2E = Check(name: "e2e", outcome: .pending, link: nil)

func comment(_ id: String, by author: String = "alice", _ body: String = "Please rename this.", association: String = "MEMBER") -> Feedback {
    Feedback(id: id, author: author, association: association, body: body, url: nil)
}

final class FakeSource: PullRequestSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PullRequest?
    private var logs: [String: String]
    private(set) var viewerCalls = 0

    init(_ pullRequest: PullRequest?, logs: [String: String] = [:]) {
        current = pullRequest
        self.logs = logs
    }

    func set(_ pullRequest: PullRequest?) {
        lock.withLock { current = pullRequest }
    }

    func viewer() throws -> String {
        lock.withLock { viewerCalls += 1 }
        return "me"
    }

    func pullRequest() throws -> PullRequest? {
        lock.withLock { current }
    }

    func failedLog(of check: Check, in pullRequest: PullRequest) throws -> String? {
        lock.withLock { logs[check.name] }
    }
}

final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func append(_ data: Data) {
        lock.withLock { lines.append(data) }
    }

    var messages: [[String: Any]] {
        lock.withLock { lines }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    var notifications: [[String: Any]] {
        messages.filter { $0["method"] as? String == "notifications/claude/channel" }
    }

    func reply(to id: Int) -> [String: Any]? {
        messages.first { ($0["id"] as? Int) == id }
    }
}
