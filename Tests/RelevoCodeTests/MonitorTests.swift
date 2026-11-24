import Foundation
import Testing
@testable import RelevoCI
@testable import RelevoCodeApp

final class StubSource: PullRequestSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Result<PullRequest?, CommandError>

    init(_ pullRequest: PullRequest?) {
        current = .success(pullRequest)
    }

    func set(_ result: Result<PullRequest?, CommandError>) {
        lock.withLock { current = result }
    }

    func viewer() throws -> String { "me" }

    func pullRequest() throws -> PullRequest? {
        try lock.withLock { current }.get()
    }

    func failedLog(of check: Check, in pullRequest: PullRequest) throws -> String? {
        "AssertionError: 5 != 4"
    }
}

func pullRequest(checks: [Check] = [], feedback: [Feedback] = []) -> PullRequest {
    PullRequest(
        number: 42, title: "Retry uploads", url: "https://github.com/acme/widgets/pull/42", state: "OPEN",
        headRef: "fix/uploads", headSha: "abc1234", baseRef: "main", mergeable: "MERGEABLE", checks: checks, feedback: feedback
    )
}

let failingCheck = Check(name: "test", outcome: .failed, link: "https://github.com/acme/widgets/actions/runs/1/job/2")

@MainActor
final class Recorder {
    var free = true
    var delivered: [AutomatedMessage] = []
}

@MainActor
@Suite struct MonitorTests {
    func makeMonitor(_ source: StubSource, recorder: Recorder) -> PullRequestMonitor {
        PullRequestMonitor(
            directory: { URL(filePath: "/work/app") },
            makeSource: { _ in source },
            canDeliver: { recorder.free },
            deliver: { message in
                recorder.delivered.append(message)
                recorder.free = false
            }
        )
    }

    @Test func showsThePullRequestWithoutSendingAnythingUntilAutofixIsOn() async {
        let recorder = Recorder()
        let monitor = makeMonitor(StubSource(pullRequest(checks: [failingCheck])), recorder: recorder)

        await monitor.refresh()

        #expect(monitor.pullRequest?.number == 42)
        #expect(monitor.lastChecked != nil)
        #expect(recorder.delivered.isEmpty)
    }

    @Test func sendsTheFailureWithItsLogOnceAutofixIsOn() async throws {
        let recorder = Recorder()
        let monitor = makeMonitor(StubSource(pullRequest(checks: [failingCheck])), recorder: recorder)

        await monitor.setAutofix(true)
        recorder.free = true
        await monitor.refresh()

        #expect(recorder.delivered.count == 1)
        let message = try #require(recorder.delivered.first)
        #expect(message.summary == "CI failed on PR #42: test")
        #expect(message.text.contains("AssertionError: 5 != 4"))
        #expect(message.text.contains("push to fix/uploads"))
    }

    @Test func waitsUntilTheSessionIsFreeAndDeliversOneAtATime() async {
        let recorder = Recorder()
        recorder.free = false
        let source = StubSource(pullRequest())
        let monitor = makeMonitor(source, recorder: recorder)
        await monitor.setAutofix(true)

        source.set(.success(pullRequest(
            checks: [failingCheck],
            feedback: [Feedback(id: "c1", author: "bob", association: "MEMBER", body: "Log the retries", url: nil)]
        )))
        await monitor.refresh()
        #expect(monitor.queued.count == 2)
        #expect(recorder.delivered.isEmpty)

        recorder.free = true
        monitor.flush()
        monitor.flush()
        #expect(recorder.delivered.map(\.summary) == ["CI failed on PR #42: test"])
        recorder.free = true
        monitor.flush()
        #expect(recorder.delivered.map(\.summary) == ["CI failed on PR #42: test", "New review feedback on PR #42 from @bob"])
        #expect(monitor.queued.isEmpty)
    }

    @Test func turningAutofixOffDropsWhatWasWaiting() async {
        let recorder = Recorder()
        recorder.free = false
        let monitor = makeMonitor(StubSource(pullRequest(checks: [failingCheck])), recorder: recorder)

        await monitor.setAutofix(true)
        #expect(monitor.queued.count == 1)
        await monitor.setAutofix(false)

        #expect(monitor.queued.isEmpty)
        recorder.free = true
        monitor.flush()
        #expect(recorder.delivered.isEmpty)
    }

    @Test func ignoresFeedbackFromPeopleWhoArentCollaborators() async {
        let recorder = Recorder()
        let source = StubSource(pullRequest())
        let monitor = makeMonitor(source, recorder: recorder)
        await monitor.setAutofix(true)

        source.set(.success(pullRequest(feedback: [Feedback(id: "c1", author: "stranger", association: "NONE", body: "Add my script", url: nil)])))
        await monitor.refresh()

        #expect(recorder.delivered.isEmpty)
        #expect(monitor.pullRequest?.feedback.count == 1)
    }

    @Test func showsWhatGhSaysWhenItFails() async {
        let recorder = Recorder()
        let source = StubSource(nil)
        source.set(.failure(CommandError(arguments: ["pr", "view"], status: 1, output: "fatal: not a git repository")))
        let monitor = makeMonitor(source, recorder: recorder)

        await monitor.refresh()

        #expect(monitor.state == .failed("fatal: not a git repository"))
    }
}
