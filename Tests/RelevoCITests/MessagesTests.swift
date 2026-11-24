import Testing
@testable import RelevoCI

@Suite struct MessagesTests {
    @Test func aCIFailureNamesTheChecksAndIncludesTheirLogs() {
        let pullRequest = makePullRequest(sha: "0123456789", checks: [failingTest])
        let message = Event.checksFailed(pullRequest, [failingTest]).message(logs: ["test": "XCTAssertEqual failed: 3 != 2"])

        #expect(message.content.contains("CI failed on PR #42 (fix/uploads at 0123456)"))
        #expect(message.content.contains("- test (https://github.com/acme/widgets/actions/runs/111/job/222)"))
        #expect(message.content.contains("XCTAssertEqual failed: 3 != 2"))
        #expect(message.content.contains("push to fix/uploads"))
        #expect(message.meta == ["pr": "42", "branch": "fix/uploads", "sha": "0123456", "kind": "ci_failure"])
    }

    @Test func feedbackQuotesEachCommentWithItsAuthorAndPlace() {
        let inline = Feedback(id: "inline-1", author: "bob", association: "MEMBER", body: "Use backoff.\nAnd log it.", url: "https://example.com/r1", location: "Upload.swift:17")
        let review = Feedback(id: "PRR_1", author: "carol", association: "OWNER", body: "Too big.", url: nil, verdict: "CHANGES_REQUESTED")
        let message = Event.feedback(makePullRequest(), [inline, review]).message()

        #expect(message.content.contains("- @bob on Upload.swift:17 (https://example.com/r1):\n  > Use backoff.\n  > And log it."))
        #expect(message.content.contains("- @carol, requesting changes:\n  > Too big."))
        #expect(message.content.contains("Do not post replies on GitHub"))
        #expect(message.meta["kind"] == "review_feedback")
    }

    @Test func aConflictAsksForAMergeNotAForcePush() {
        let message = Event.conflict(makePullRequest(mergeable: "CONFLICTING")).message()

        #expect(message.content.contains("has merge conflicts with main"))
        #expect(message.content.contains("Merge origin/main into fix/uploads"))
        #expect(message.content.contains("Do not rebase or force-push"))
        #expect(message.meta["kind"] == "merge_conflict")
    }

    @Test func metaKeysAreIdentifiers() {
        let keys = Event.conflict(makePullRequest()).message().meta.keys
        #expect(keys.allSatisfy { $0.wholeMatch(of: /[a-zA-Z_][a-zA-Z0-9_]*/) != nil })
    }

    @Test func theSummaryListsChecksLogsAndFeedback() {
        let feedback = [comment("1", by: "alice", "Rename\nthis"), comment("2", by: "stranger", "Hi", association: "NONE")]
        let pullRequest = makePullRequest(checks: [failingTest, pendingE2E], feedback: feedback)
        let summary = pullRequest.summary(logs: ["test": "boom"])

        #expect(summary.contains("PR #42: Retry flaky uploads"))
        #expect(summary.contains("- test: failed"))
        #expect(summary.contains("- e2e: pending"))
        #expect(summary.contains("Failed steps of test, last lines:\n```\nboom\n```"))
        #expect(summary.contains("- @alice: Rename this"))
        #expect(summary.contains("- @stranger [not a collaborator]: Hi"))
    }
}

@Suite struct LogExcerptTests {
    @Test func dropsTheJobStepAndTimestampColumnsAndColors() {
        let log = "test\tRun swift test\t\u{FEFF}2026-11-23T23:41:04.1234567Z \u{1B}[31merror:\u{1B}[0m 3 != 2\ntest\tRun swift test\t2026-11-23T23:41:05.0000000Z done"

        #expect(LogExcerpt.make(from: log) == "error: 3 != 2\ndone")
    }

    @Test func keepsOnlyTheLastLinesAndCharacters() {
        let log = (1...10).map { "line \($0)" }.joined(separator: "\n")

        #expect(LogExcerpt.make(from: log, lines: 3) == "line 8\nline 9\nline 10")
        #expect(LogExcerpt.make(from: log, lines: 3, characters: 7) == "line 10")
    }
}
