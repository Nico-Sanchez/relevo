import Foundation
import Testing
@testable import RelevoCI

@Suite struct PullRequestDecodingTests {
    @Test func readsTheBranchAndEveryCheckOutcome() throws {
        let pullRequest = try PullRequest.decode(pullRequestResponse)

        #expect(pullRequest.number == 42)
        #expect(pullRequest.isOpen)
        #expect(pullRequest.headRef == "fix/uploads")
        #expect(pullRequest.shortSha == "0123456")
        #expect(pullRequest.checks.map(\.name) == ["test", "lint", "label", "e2e", "deploy/preview"])
        #expect(pullRequest.checks.map(\.outcome) == [.failed, .passed, .skipped, .pending, .failed])
    }

    @Test func keepsOnlyFeedbackSomeoneCouldActOn() throws {
        let pullRequest = try PullRequest.decode(pullRequestResponse)

        #expect(pullRequest.feedback.map(\.id) == ["IC_1", "PRR_1"])
        #expect(pullRequest.feedback.map(\.association) == ["MEMBER", "COLLABORATOR"])
        #expect(pullRequest.feedback.last?.verdict == "CHANGES_REQUESTED")
    }

    @Test func readsInlineCommentsWithTheirLocation() throws {
        let inline = try PullRequest.decodeInlineComments(inlineCommentsResponse)

        #expect(inline.map(\.id) == ["inline-901", "inline-902"])
        #expect(inline.map(\.location) == ["Sources/Upload.swift:17", "Sources/Upload.swift"])
        #expect(inline.map(\.isFromCollaborator) == [true, false])
    }

    @Test func findsTheRunAndJobOfAnActionsCheck() {
        #expect(failingTest.run == RunReference(id: "111", job: "222"))
        #expect(Check(name: "x", outcome: .failed, link: "https://github.com/acme/widgets/actions/runs/333").run == RunReference(id: "333", job: nil))
        #expect(Check(name: "x", outcome: .failed, link: "https://deploys.example.com/42").run == nil)
    }

    @Test func findsTheRepositoryFromTheURL() {
        let repository = makePullRequest().repository

        #expect(repository == Repository(host: "github.com", owner: "acme", name: "widgets"))
        #expect(repository?.slug == "github.com/acme/widgets")
    }
}
