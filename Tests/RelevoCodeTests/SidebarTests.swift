import Foundation
import Testing
import RelevoCI
@testable import RelevoCode
@testable import RelevoCodeApp

@MainActor
@Suite struct SidebarTests {
    let second = ClaudeAccount(configDirectory: URL(filePath: "/Users/ana/.claude-accounts/second"))

    func model() -> AppModel {
        let model = AppModel(defaults: UserDefaults(suiteName: "relevo-tests-\(UUID().uuidString)")!)
        model.accounts = [.standard, second]
        return model
    }

    func session(resuming id: String? = nil, in account: ClaudeAccount = .standard) -> Session {
        Session(configuration: SessionConfiguration(directory: URL(filePath: "/work/app"), configDirectory: account.configDirectory, resume: id), accountName: "Ana")
    }

    func past(_ id: String) -> PastSession {
        PastSession(id: id, file: URL(filePath: "/x"), directory: URL(filePath: "/work/app"), title: id, lastActivity: .now, branch: nil)
    }

    func live(_ id: String, in account: ClaudeAccount = .standard) -> Session {
        let session = session(in: account)
        session.apply(.sessionStarted(sessionID: id, model: nil, permissionMode: nil, directory: nil))
        session.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        return session
    }

    @Test func marksAFinishedTurnUnreadUntilYouLookAtIt() {
        let model = model()
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
        let model = model()
        let session = session()
        model.sessions = [session]
        model.selection = .open(session.id)

        session.apply(.permissionRequest(PermissionRequest(
            id: "p1", toolName: "Bash", displayName: "Bash", input: .object([:]), description: nil, suggestions: [], toolUseID: nil
        )))

        #expect(model.attention(of: session) == .waiting)
    }

    @Test func remembersWhatYouSawOfADesktopSession() {
        let model = model()
        let past = past("desk")
        model.desktop = [past.id: DesktopSession(title: nil, isArchived: false, lastTurnEnded: .now.addingTimeInterval(-60), lastFocused: nil)]
        #expect(model.attention(of: past) == .unread)

        let opened = session(resuming: past.id)
        model.sessions = [opened]
        model.markSeen(.open(opened.id))

        #expect(model.attention(of: past) == nil)
    }

    @Test func combinesDesktopsPullRequestsWithTheOneOnTheBranch() async {
        let model = model()
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

    @Test func showsOnlyTheCurrentAccountsConversations() {
        let model = model()
        let mine = session()
        let theirs = session(in: second)
        model.sessions = [mine, theirs]
        model.recent = [past("p-main"), past("p-second")]
        model.owners = ["p-main": ClaudeAccount.standard.id, "p-second": second.id]
        model.selection = .open(mine.id)

        #expect(model.visibleSessions.map(\.id) == [mine.id])
        #expect(model.visibleRecent.map(\.id) == ["p-main"])

        model.switchAccount(to: second)

        #expect(model.currentAccount == second)
        #expect(model.visibleSessions.map(\.id) == [theirs.id])
        #expect(model.visibleRecent.map(\.id) == ["p-second"])
        #expect(model.selection == .open(theirs.id))
    }

    @Test func movesALiveConversationToAnotherAccount() throws {
        let model = model()
        let original = live("live-1")
        model.sessions = [original]
        model.selection = .open(original.id)

        model.handOff(original, to: second)

        let moved = try #require(model.sessions.first)
        #expect(model.sessions.count == 1)
        #expect(moved.id != original.id)
        #expect(moved.configuration.configDirectory == second.configDirectory)
        #expect(moved.configuration.resume == "live-1")
        #expect(!moved.configuration.fork)
        #expect(model.currentAccount == second)
        #expect(model.selection == .open(moved.id))
        #expect(model.owner(of: past("live-1")) == second.id)
    }

    @Test func copiesAConversationThatDesktopStillHasOpen() throws {
        let model = model()
        let original = live("desk-1")
        model.sessions = [original]
        model.desktop = ["desk-1": DesktopSession(title: nil, isArchived: false)]

        model.handOff(original, to: second)

        let copy = try #require(model.sessions.first)
        #expect(copy.configuration.fork)
        #expect(copy.configuration.configDirectory == second.configDirectory)
        #expect(model.owner(of: past("desk-1")) == ClaudeAccount.standard.id)
    }

    @Test func waitsForTheTurnToEndBeforeMovingIt() {
        let model = model()
        let busy = session()
        busy.apply(.sessionStarted(sessionID: "busy-1", model: nil, permissionMode: nil, directory: nil))
        busy.apply(.status("requesting"))
        model.sessions = [busy]

        model.handOff(busy, to: second)

        #expect(!model.canHandOff(busy))
        #expect(model.sessions.map(\.id) == [busy.id])
        #expect(model.currentAccount == .standard)
    }

    @Test func movesARecentOrDormantConversation() throws {
        let model = model()
        model.recent = [past("p-1"), past("p-2")]

        model.handOff(past("p-1"), to: second)

        let opened = try #require(model.sessions.first)
        #expect(opened.status == .dormant)
        #expect(opened.configuration.configDirectory == second.configDirectory)
        #expect(opened.configuration.resume == "p-1")
        #expect(model.owner(of: past("p-1")) == second.id)
        #expect(model.currentAccount == second)

        model.switchAccount(to: .standard)
        model.open(past("p-2"))
        let dormant = try #require(model.sessions.first)
        model.handOff(dormant, to: second)

        #expect(model.sessions.first?.id == dormant.id)
        #expect(dormant.configuration.configDirectory == second.configDirectory)
        #expect(model.owner(of: past("p-2")) == second.id)
        #expect(model.currentAccount == second)
    }

    @Test func pointsAtOtherAccountsThatNeedYou() {
        let model = model()
        let waiting = session(in: second)
        waiting.apply(.permissionRequest(PermissionRequest(
            id: "p1", toolName: "Bash", displayName: "Bash", input: .object([:]), description: nil, suggestions: [], toolUseID: nil
        )))
        model.sessions = [waiting]

        #expect(model.attention(of: second) == .waiting)
        #expect(model.attention(of: .standard) == nil)
        #expect(model.attentionElsewhere == .waiting)

        model.switchAccount(to: second)
        #expect(model.attentionElsewhere == nil)
    }
}
