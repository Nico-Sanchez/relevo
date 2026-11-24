import Foundation
import Testing
import RelevoCI
@testable import RelevoCode
@testable import RelevoCodeApp

@MainActor
@Suite struct SidebarTests {
    let second = ClaudeAccount(configDirectory: URL(filePath: "/Users/ana/.claude-accounts/second"))

    func model(_ defaults: UserDefaults = UserDefaults(suiteName: "relevo-tests-\(UUID().uuidString)")!) -> AppModel {
        let model = AppModel(defaults: defaults)
        model.accounts = [.standard, second]
        return model
    }

    func window(_ model: AppModel, on account: ClaudeAccount = .standard) -> WindowModel {
        let window = WindowModel(app: model, accountID: account.id)
        window.attach()
        return window
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

    func waitingForPermission(_ session: Session) {
        session.apply(.permissionRequest(PermissionRequest(
            id: "p1", toolName: "Bash", displayName: "Bash", input: .object([:]), description: nil, suggestions: [], toolUseID: nil
        )))
    }

    @Test func marksAFinishedTurnUnreadUntilYouLookAtIt() {
        let model = model()
        let watched = session()
        let background = session()
        model.sessions = [watched, background]
        let window = window(model)
        window.selection = .open(watched.id)
        window.attach()

        watched.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        background.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        #expect(model.attention(of: watched) == nil)
        #expect(model.attention(of: background) == .unread)

        model.markSeen(.open(watched.id))
        window.selection = .open(background.id)
        window.attach()
        model.markSeen(.open(background.id))
        #expect(model.attention(of: watched) == nil)
        #expect(model.attention(of: background) == nil)
    }

    @Test func showsAPermissionPromptAsWaitingEvenWhenSelected() {
        let model = model()
        let session = session()
        model.sessions = [session]
        let window = window(model)
        window.selection = .open(session.id)
        window.attach()

        waitingForPermission(session)

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

    @Test func showsOnlyTheWindowsAccountsConversations() {
        let model = model()
        let mine = session()
        let theirs = session(in: second)
        model.sessions = [mine, theirs]
        model.recent = [past("p-main"), past("p-second")]
        model.owners = ["p-main": ClaudeAccount.standard.id, "p-second": second.id]
        let window = window(model)
        window.selection = .open(mine.id)

        #expect(window.visibleSessions.map(\.id) == [mine.id])
        #expect(window.visibleRecent.map(\.id) == ["p-main"])

        window.switchAccount(to: second)

        #expect(window.account == second)
        #expect(window.visibleSessions.map(\.id) == [theirs.id])
        #expect(window.visibleRecent.map(\.id) == ["p-second"])
        #expect(window.selection == .open(theirs.id))
    }

    @Test func keepsEachWindowOnItsOwnAccountAndSelection() {
        let model = model()
        let mine = session()
        let theirs = session(in: second)
        model.sessions = [mine, theirs]
        let first = window(model)
        let other = window(model, on: second)

        first.selection = .open(mine.id)
        other.selection = .open(theirs.id)

        #expect(first.selected?.id == mine.id)
        #expect(other.selected?.id == theirs.id)
        #expect(first.account == .standard)
        #expect(other.account == second)
    }

    @Test func movesALiveConversationToAnotherAccount() throws {
        let model = model()
        let original = live("live-1")
        model.sessions = [original]
        let window = window(model)
        window.selection = .open(original.id)

        window.handOff(original, to: second)

        let moved = try #require(model.sessions.first)
        #expect(model.sessions.count == 1)
        #expect(moved.id != original.id)
        #expect(moved.configuration.configDirectory == second.configDirectory)
        #expect(moved.configuration.resume == "live-1")
        #expect(!moved.configuration.fork)
        #expect(window.account == second)
        #expect(window.selection == .open(moved.id))
        #expect(model.owner(of: past("live-1")) == second.id)
    }

    @Test func sendsAMovedConversationToItsAccountsWindow() throws {
        let model = model()
        let original = live("live-2")
        let staying = session()
        model.sessions = [original, staying]
        let first = window(model)
        let other = window(model, on: second)
        var opened: [String] = []
        first.openWindow = { opened.append($0) }
        first.selection = .open(original.id)

        first.handOff(original, to: second)

        let moved = try #require(model.sessions.first { $0.configuration.resume == "live-2" })
        #expect(first.account == .standard)
        #expect(first.selection == .open(staying.id))
        #expect(opened == [second.id])
        #expect(model.focusRequest == FocusRequest(accountID: second.id, session: moved.id))

        other.receive(model.focusRequest)

        #expect(other.selection == .open(moved.id))
        #expect(model.focusRequest == nil)
    }

    @Test func copiesAConversationThatDesktopStillHasOpen() throws {
        let model = model()
        let original = live("desk-1")
        model.sessions = [original]
        model.desktop = ["desk-1": DesktopSession(title: nil, isArchived: false)]

        let copy = try #require(model.handOff(original, to: second))

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
        let window = window(model)

        window.handOff(busy, to: second)

        #expect(!model.canHandOff(busy))
        #expect(model.sessions.map(\.id) == [busy.id])
        #expect(window.account == .standard)
    }

    @Test func movesARecentOrDormantConversation() throws {
        let model = model()
        model.recent = [past("p-1"), past("p-2")]
        let window = window(model)

        window.handOff(past("p-1"), to: second)

        let opened = try #require(model.sessions.first)
        #expect(opened.status == .dormant)
        #expect(opened.configuration.configDirectory == second.configDirectory)
        #expect(opened.configuration.resume == "p-1")
        #expect(model.owner(of: past("p-1")) == second.id)
        #expect(window.account == second)

        window.switchAccount(to: .standard)
        window.open(past("p-2"))
        let dormant = try #require(model.sessions.first)
        window.handOff(dormant, to: second)

        #expect(model.sessions.first?.id == dormant.id)
        #expect(dormant.configuration.configDirectory == second.configDirectory)
        #expect(model.owner(of: past("p-2")) == second.id)
        #expect(window.account == second)
    }

    @Test func pointsAtOtherAccountsThatNeedYou() {
        let model = model()
        let waiting = session(in: second)
        waitingForPermission(waiting)
        model.sessions = [waiting]
        let window = window(model)

        #expect(model.attention(of: second) == .waiting)
        #expect(model.attention(of: .standard) == nil)
        #expect(window.attentionElsewhere == .waiting)

        window.switchAccount(to: second)
        #expect(window.attentionElsewhere == nil)
    }

    @Test func opensNewWindowsOnAnAccountWithoutOne() {
        let model = model()
        #expect(WindowModel(app: model, accountID: nil).account == .standard)

        let first = window(model)
        #expect(WindowModel(app: model, accountID: nil).account == second)

        window(model, on: second).attach()
        #expect(WindowModel(app: model, accountID: nil).account == .standard)

        first.detach()
        #expect(model.hasWindow(for: second, besides: first.id))
        #expect(!model.hasWindow(for: .standard, besides: first.id))
    }

    @Test func givesEachAccountAColorYouCanChange() {
        let defaults = UserDefaults(suiteName: "relevo-tests-\(UUID().uuidString)")!
        let model = model(defaults)

        #expect(model.theme(of: .standard) == .orange)
        #expect(model.theme(of: second) == .blue)

        model.setTheme(.teal, for: second)

        #expect(model.theme(of: second) == .teal)
        #expect(self.model(defaults).theme(of: second) == .teal)
    }
}
