import Foundation
import Testing
import RelevoCI
@testable import RelevoCode
@testable import RelevoCodeApp

@MainActor
@Suite struct SidebarTests {
    func session(resuming id: String? = nil) -> Session {
        Session(configuration: SessionConfiguration(directory: URL(filePath: "/work/app"), resume: id), accountName: "Ana")
    }

    @Test func marksAFinishedTurnUnreadUntilYouLookAtIt() {
        let model = AppModel()
        let watched = session()
        let background = session()
        model.sessions = [watched, background]
        model.selection = .open(watched.id)

        watched.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        background.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        #expect(model.attention(of: watched) == nil)
        #expect(model.attention(of: background) == .unread)

        model.markSeen(.open(watched.id))
        model.selection = .open(background.id)
        model.markSeen(.open(background.id))
        #expect(model.attention(of: watched) == nil)
        #expect(model.attention(of: background) == nil)
    }

    @Test func showsAPermissionPromptAsWaitingEvenWhenSelected() {
        let model = AppModel()
        let session = session()
        model.sessions = [session]
        model.selection = .open(session.id)

        session.apply(.permissionRequest(PermissionRequest(
            id: "p1", toolName: "Bash", displayName: "Bash", input: .object([:]), description: nil, suggestions: [], toolUseID: nil
        )))

        #expect(model.attention(of: session) == .waiting)
    }

    @Test func remembersWhatYouSawOfADesktopSession() {
        let model = AppModel()
        let past = PastSession(id: "desk-\(UUID().uuidString)", file: URL(filePath: "/x"), directory: URL(filePath: "/work/app"), title: "", lastActivity: .now, branch: nil)
        model.desktop = [past.id: DesktopSession(title: nil, isArchived: false, lastTurnEnded: .now.addingTimeInterval(-60), lastFocused: nil)]
        #expect(model.attention(of: past) == .unread)

        let opened = session(resuming: past.id)
        model.sessions = [opened]
        model.markSeen(.open(opened.id))

        #expect(model.attention(of: past) == nil)
        model.seen[past.id] = nil
    }

    @Test func combinesDesktopsPullRequestsWithTheOneOnTheBranch() async {
        let model = AppModel()
        let session = session(resuming: "abc")
        model.desktop = ["abc": DesktopSession(title: nil, isArchived: false, pullRequests: ["https://github.com/acme/widgets/pull/1": .merged])]
        #expect(model.pullRequests(of: session) == PullRequestBadge([.merged]))

        let source = StubSource(pullRequest())
        let monitor = PullRequestMonitor(
            directory: { URL(filePath: "/work/app") }, makeSource: { _ in source }, canDeliver: { false }, deliver: { _ in }
        )
        model.monitors[session.id] = monitor
        await monitor.refresh()

        #expect(model.pullRequests(of: session) == PullRequestBadge([.merged, .open]))
    }
}
