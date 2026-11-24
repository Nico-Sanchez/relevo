import Foundation
import Testing
@testable import RelevoCode
@testable import RelevoCodeApp

@MainActor
@Suite struct NotificationTests {
    let second = ClaudeAccount(configDirectory: URL(filePath: "/Users/ana/.claude-accounts/second"))

    func setUp(active: Bool = true) -> (AppModel, SilentNotifier) {
        let notifier = SilentNotifier()
        let model = AppModel(defaults: UserDefaults(suiteName: "relevo-tests-\(UUID().uuidString)")!, notifier: notifier)
        model.accounts = [.standard, second]
        model.accountInfo = [ClaudeAccount.standard.id: AccountInfo(email: "ana@example.com", organization: nil, subscription: nil)]
        model.isActive = { active }
        model.activate = {}
        return (model, notifier)
    }

    func session(in account: ClaudeAccount = .standard, title: String = "Release notes") -> Session {
        Session(configuration: SessionConfiguration(directory: URL(filePath: "/work/app"), configDirectory: account.configDirectory), accountName: "Ana", title: title)
    }

    func permission(_ tool: String, _ input: [String: Any]) -> Incoming {
        .permissionRequest(PermissionRequest(id: "p1", toolName: tool, displayName: tool, input: JSONValue(input), description: nil, suggestions: [], toolUseID: nil))
    }

    @Test func tellsYouWhenASessionYouAreNotWatchingNeedsYou() throws {
        let (model, notifier) = setUp()
        let session = session()
        model.sessions = [session]
        model.observe(session)

        session.apply(permission("Bash", ["command": "swift test\nmore"]))

        let banner = try #require(notifier.posted.first)
        #expect(banner == Banner(session: session.id, title: "Release notes", subtitle: "ana@example.com", body: "Wants to use Bash: swift test", sound: true))
    }

    @Test func showsTheQuestionClaudeAsks() throws {
        let (model, notifier) = setUp()
        let session = session()
        model.observe(session)

        session.apply(permission("AskUserQuestion", ["questions": [["question": "Which audience?", "options": [["label": "Customers"]]]]]))

        #expect(notifier.posted.first?.body == "Which audience?")
    }

    @Test func staysQuietWhileYouAreLookingAtIt() {
        let (model, notifier) = setUp(active: true)
        let session = session()
        model.sessions = [session]
        model.observe(session)
        let window = WindowModel(app: model, accountID: ClaudeAccount.standard.id)
        window.selection = .open(session.id)
        window.attach()

        session.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))

        #expect(notifier.posted.isEmpty)
    }

    @Test func tellsYouWhenATurnEndsWhileTheAppIsInTheBackground() throws {
        let (model, notifier) = setUp(active: false)
        let session = session()
        model.sessions = [session]
        model.observe(session)
        let window = WindowModel(app: model, accountID: ClaudeAccount.standard.id)
        window.selection = .open(session.id)
        window.attach()

        session.append(.assistant("Released 2.4.\nThe notes are in CHANGELOG.md."))
        session.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        session.apply(.exited(status: 1, message: "Not logged in"))

        #expect(notifier.posted.map(\.body) == ["Released 2.4.", "Stopped: Not logged in"])
        #expect(notifier.posted.map(\.sound) == [false, false])
    }

    @Test func clearsTheNotificationOnceYouOpenTheSession() {
        let (model, notifier) = setUp()
        let session = session()
        model.sessions = [session]
        let window = WindowModel(app: model, accountID: ClaudeAccount.standard.id)

        window.selection = .open(session.id)
        window.attach()

        #expect(notifier.withdrawn == [session.id])
    }

    @Test func clickingTheNotificationOpensTheSessionInItsAccount() {
        let (model, notifier) = setUp(active: false)
        let session = session(in: second)
        model.sessions = [session]
        var opened: [String] = []
        var activated = false
        model.openWindow = { opened.append($0) }
        model.activate = { activated = true }
        let window = WindowModel(app: model, accountID: ClaudeAccount.standard.id)
        window.attach()

        notifier.onOpen?(session.id)

        #expect(model.focusRequest == FocusRequest(accountID: second.id, session: session.id))
        #expect(opened == [second.id])
        #expect(activated)

        let theirs = WindowModel(app: model, accountID: second.id)
        theirs.attach()
        theirs.receive(model.focusRequest)
        #expect(theirs.selection == .open(session.id))

        opened = []
        notifier.onOpen?(session.id)
        #expect(opened.isEmpty)
    }

    @Test func countsTheSessionsWaitingOnYou() {
        let (model, _) = setUp()
        let waiting = session()
        let other = session(in: second)
        let idle = session()
        model.sessions = [waiting, other, idle]

        waiting.apply(permission("Bash", ["command": "ls"]))
        other.apply(permission("Edit", ["file_path": "/work/app/a.swift"]))

        #expect(model.waitingCount == 2)
    }
}
