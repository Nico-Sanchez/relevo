import Foundation
import Testing
@testable import RelevoCode

func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "relevo-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

let transcriptLines = [
    #"{"type":"queue-operation","operation":"enqueue"}"#,
    #"{"type":"user","isMeta":true,"cwd":"/work/app","message":{"role":"user","content":"<system-reminder>context</system-reminder>"}}"#,
    #"{"type":"user","cwd":"/work/app","gitBranch":"main","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\nnoise\n</system-reminder>"},{"type":"text","text":"Fix the login bug"}]}}"#,
    #"{"type":"assistant","cwd":"/work/app","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Looking at it."}]}}"#,
    #"{"type":"assistant","cwd":"/work/app","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/work/app/login.swift"}}]}}"#,
    #"{"type":"user","cwd":"/work/app","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Updated"}]},"toolUseResult":{"structuredPatch":[{"oldStart":3,"newStart":3,"lines":["-a","+b"]}]}}"#,
    #"{"type":"assistant","isSidechain":true,"message":{"id":"msg_side","role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}"#,
    #"{"type":"assistant","cwd":"/work/app","message":{"id":"msg_2","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"swift test"}}]}}"#,
    #"{"type":"system","subtype":"compact_boundary"}"#,
    #"{"type":"user","cwd":"/work/app","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
    #"{"type":"custom-title","customTitle":"Login bug"}"#,
    #"{"type":"relocated","relocatedCwd":"/work/app/.claude/worktrees/login-bug"}"#,
]

@Suite struct LibraryTests {
    func writeTranscript(_ lines: [String], named name: String = "11111111-2222-3333-4444-555555555555") throws -> URL {
        let project = try temporaryFolder().appending(path: "-work-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appending(path: "\(name).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func summarizesASessionWithItsTitleFolderAndBranch() throws {
        let file = try writeTranscript(transcriptLines)
        let session = try #require(SessionLibrary.summary(of: file, lastActivity: .distantPast))

        #expect(session.id == "11111111-2222-3333-4444-555555555555")
        #expect(session.title == "Login bug")
        #expect(session.directory.path == "/work/app/.claude/worktrees/login-bug")
        #expect(session.branch == "main")
        #expect(session.projectName == "app · login-bug")
    }

    @Test func fallsBackToTheFirstRealPromptForTheTitle() throws {
        let file = try writeTranscript(Array(transcriptLines.prefix(4)))

        #expect(SessionLibrary.summary(of: file, lastActivity: .distantPast)?.title == "Fix the login bug")
        #expect(SessionLibrary.summary(of: try writeTranscript([transcriptLines[0]]), lastActivity: .distantPast) == nil)
    }

    @Test func listsTheMostRecentSessionsAcrossProjects() throws {
        let older = try writeTranscript(transcriptLines, named: "older")
        let newer = try writeTranscript(Array(transcriptLines.prefix(4)), named: "newer")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)
        let pools = [older, newer].map { $0.deletingLastPathComponent().deletingLastPathComponent() }

        #expect(SessionLibrary.recent(in: pools).map(\.id) == ["newer", "older"])
        #expect(SessionLibrary.recent(in: pools, limit: 1).map(\.id) == ["newer"])
    }

    @Test func keepsOnlySessionsWorthContinuing() {
        func past(_ id: String, _ path: String) -> PastSession {
            PastSession(id: id, file: URL(filePath: "/x"), directory: URL(filePath: path), title: id, lastActivity: .now, branch: nil)
        }
        let sessions = [
            past("live", "/work/app"),
            past("archived", "/work/app"),
            past("open-in-desktop", "/work/app/.claude/worktrees/fix"),
            past("probe", "/private/tmp/claude-501/scratch/proto"),
            past("test", "/var/folders/6z/T/relevo-live-1"),
            past("gone", "/work/removed-worktree"),
        ]
        let desktop = [
            "archived": DesktopSession(title: nil, isArchived: true),
            "open-in-desktop": DesktopSession(title: nil, isArchived: false),
        ]

        let kept = SessionLibrary.relevant(sessions, desktop: desktop) { $0.path != "/work/removed-worktree" }

        #expect(kept.map(\.id) == ["live", "open-in-desktop"])
    }

    @Test func namesTheRepositoryAndWorktreeOfASession() {
        let worktree = PastSession(id: "a", file: URL(filePath: "/x"), directory: URL(filePath: "/work/vertex/.claude/worktrees/fix-login"), title: "", lastActivity: .now, branch: nil)
        let plain = PastSession(id: "b", file: URL(filePath: "/x"), directory: URL(filePath: "/work/relevo"), title: "", lastActivity: .now, branch: nil)

        #expect(worktree.repositoryName == "vertex")
        #expect(worktree.worktreeName == "fix-login")
        #expect(worktree.projectName == "vertex · fix-login")
        #expect(plain.repositoryName == "relevo")
        #expect(plain.worktreeName == nil)
        #expect(plain.projectName == "relevo")
    }

    @Test func readsDesktopsSessionsByTheirCLIIdentifier() throws {
        let root = try temporaryFolder()
        let folder = root.appending(path: "account/org")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"cliSessionId":"abc","title":"Dependabot alerts","isArchived":false}"#.write(to: folder.appending(path: "local_1.json"), atomically: true, encoding: .utf8)
        try #"{"cliSessionId":"def","isArchived":true}"#.write(to: folder.appending(path: "local_2.json"), atomically: true, encoding: .utf8)
        try """
            {"cliSessionId":"ghi","title":"Invoices","isArchived":false,
             "prs":[{"prNumber":4,"url":"https://github.com/a/b/pull/4","state":"MERGED"},
                    {"prNumber":5,"url":"https://github.com/a/b/pull/5","state":"OPEN"},
                    {"prNumber":6,"url":"https://github.com/a/b/pull/6","state":"QUEUED"}],
             "turnWrapUp":{"description":"Done.","needsUser":"Which priority?"},
             "lastTurnEdgeAt":2000000,"lastFocusedAt":1000000}
            """.write(to: folder.appending(path: "local_3.json"), atomically: true, encoding: .utf8)
        try #"{"cliSessionId":"jkl","isArchived":false,"turnWrapUp":{"description":"Done.","needsUser":""}}"#.write(to: folder.appending(path: "local_4.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appending(path: "other.json"), atomically: true, encoding: .utf8)

        let sessions = SessionLibrary.desktopSessions(in: root)
        #expect(sessions["abc"] == DesktopSession(title: "Dependabot alerts", isArchived: false, accountUUID: "account"))
        #expect(sessions["def"]?.isArchived == true)
        #expect(sessions["ghi"] == DesktopSession(
            title: "Invoices", isArchived: false,
            pullRequests: ["https://github.com/a/b/pull/4": .merged, "https://github.com/a/b/pull/5": .open],
            question: "Which priority?",
            lastTurnEnded: Date(timeIntervalSince1970: 2_000), lastFocused: Date(timeIntervalSince1970: 1_000),
            accountUUID: "account"
        ))
        #expect(sessions["jkl"]?.question == nil)
        #expect(sessions.count == 4)
    }

    func account(uuid: String?, ran sessions: [String: Date]) throws -> ClaudeAccount {
        let folder = try temporaryFolder()
        if let uuid {
            try #"{"oauthAccount":{"accountUuid":"\#(uuid)","emailAddress":"ana@example.com"}}"#
                .write(to: folder.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        }
        for (id, date) in sessions {
            let environment = folder.appending(path: "session-env/\(id)")
            try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: environment.path)
        }
        return ClaudeAccount(configDirectory: folder)
    }

    @Test func readsAnAccountsIdentityAndTheSessionsItRan() throws {
        let account = try account(uuid: "uuid-a", ran: ["s1": Date(timeIntervalSince1970: 1_000)])

        #expect(account.accountUUID() == "uuid-a")
        #expect(account.sessionRuns() == ["s1": Date(timeIntervalSince1970: 1_000)])
        #expect(try self.account(uuid: nil, ran: [:]).accountUUID() == nil)
    }

    @Test func givesEachSessionToTheAccountThatOwnsIt() throws {
        let main = try account(uuid: "uuid-main", ran: ["ran-in-both": Date(timeIntervalSince1970: 1_000), "ran-in-main": .now])
        let second = try account(uuid: "uuid-second", ran: ["ran-in-both": Date(timeIntervalSince1970: 2_000), "moved": .now])
        let desktop = [
            "desktop-second": DesktopSession(title: nil, isArchived: false, accountUUID: "uuid-second"),
            "desktop-unknown": DesktopSession(title: nil, isArchived: false, accountUUID: "uuid-elsewhere"),
        ]

        let owners = SessionOwners.resolve(
            ["ran-in-both", "ran-in-main", "moved", "desktop-second", "desktop-unknown", "unknown", "assigned-to-gone"],
            accounts: [main, second],
            assigned: ["moved": main.id, "assigned-to-gone": "/nowhere"],
            desktop: desktop
        )

        #expect(owners == [
            "ran-in-both": second.id,
            "ran-in-main": main.id,
            "moved": main.id,
            "desktop-second": second.id,
            "desktop-unknown": main.id,
            "unknown": main.id,
            "assigned-to-gone": main.id,
        ])
    }

    @Test func noticesAQuestionStillWaitingForAnAnswer() throws {
        let question = #"{"type":"assistant","cwd":"/work/app","message":{"id":"msg_9","role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"AskUserQuestion","input":{}}]}}"#
        let answer = #"{"type":"user","cwd":"/work/app","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"Option A"}]}}"#
        let title = #"{"type":"custom-title","customTitle":"Login bug"}"#

        let waiting = try writeTranscript(Array(transcriptLines.prefix(4)) + [question, title], named: "waiting")
        let answered = try writeTranscript(Array(transcriptLines.prefix(4)) + [question, answer], named: "answered")

        #expect(SessionLibrary.summary(of: waiting, lastActivity: .distantPast)?.awaitsAnswer == true)
        #expect(SessionLibrary.summary(of: answered, lastActivity: .distantPast)?.awaitsAnswer == false)
        #expect(SessionLibrary.summary(of: try writeTranscript(transcriptLines), lastActivity: .distantPast)?.awaitsAnswer == false)
    }

    @Test func showsTheMostActivePullRequestStateWithTheCount() {
        let mixed = PullRequestBadge([.merged, .open, .closed])

        #expect(PullRequestBadge([PullRequestState]()) == nil)
        #expect(PullRequestBadge([.merged])?.count == 1)
        #expect(mixed?.state == .open)
        #expect(mixed?.count == 3)
        #expect(PullRequestBadge([.closed, .merged])?.state == .merged)
    }

    @Test func flagsSessionsWaitingOnYouOrFinishedSinceYouLooked() {
        let past = PastSession(id: "a", file: URL(filePath: "/x"), directory: URL(filePath: "/work/app"), title: "", lastActivity: .now, branch: nil)
        var waiting = past
        waiting.awaitsAnswer = true
        let ended = Date(timeIntervalSince1970: 2_000)
        func desktop(question: String? = nil, focused: Date?) -> DesktopSession {
            DesktopSession(title: nil, isArchived: false, question: question, lastTurnEnded: ended, lastFocused: focused)
        }

        #expect(past.attention(desktop: nil, seen: nil) == nil)
        #expect(waiting.attention(desktop: nil, seen: .now) == .waiting)
        #expect(past.attention(desktop: desktop(question: "Which?", focused: .now), seen: .now) == .waiting)
        #expect(past.attention(desktop: desktop(focused: Date(timeIntervalSince1970: 1_000)), seen: nil) == .unread)
        #expect(past.attention(desktop: desktop(focused: nil), seen: nil) == .unread)
        #expect(past.attention(desktop: desktop(focused: Date(timeIntervalSince1970: 3_000)), seen: nil) == nil)
        #expect(past.attention(desktop: desktop(focused: nil), seen: Date(timeIntervalSince1970: 3_000)) == nil)
    }

    @Test func rebuildsTheConversationFromATranscript() throws {
        let entries = History.entries(in: try writeTranscript(transcriptLines))

        #expect(entries == [
            .user("Fix the login bug"),
            .event(.assistant(messageID: "msg_1", blocks: [.text("Looking at it.")])),
            .event(.assistant(messageID: "msg_1", blocks: [.toolUse(id: "toolu_1", name: "Edit", input: .object(["file_path": .string("/work/app/login.swift")]))])),
            .event(.toolResult(toolUseID: "toolu_1", content: "Updated", isError: false, patch: [DiffHunk(oldStart: 3, newStart: 3, lines: ["-a", "+b"])])),
            .event(.assistant(messageID: "msg_2", blocks: [.toolUse(id: "toolu_2", name: "Bash", input: .object(["command": .string("swift test")]))])),
            .compacted,
        ])
    }
}

@MainActor
@Suite struct DormantSessionTests {
    func session(_ configuration: SessionConfiguration = SessionConfiguration(directory: URL(filePath: "/work/app"), resume: "abc")) -> Session {
        Session(configuration: configuration, accountName: "Ana", title: "Login bug", dormant: true)
    }

    @Test func loadsHistoryAndWaitsForTheFirstMessage() {
        let session = session()
        session.loadHistory(History.entries(from: transcriptLines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))).map(JSONValue.init)
        }))

        #expect(session.status == .dormant)
        #expect(session.canSend)
        #expect(session.title == "Login bug")
        #expect(session.sessionID == "abc")
        let tools = session.items.compactMap { item -> ToolCall? in
            if case .tool(let call) = item.kind { call } else { nil }
        }
        #expect(tools.map(\.state) == [.done, .stopped])
        #expect(tools.first?.patch.first?.lines == ["-a", "+b"])
        #expect(session.items.last?.kind == .notice(.compacted))
    }

    @Test func showsOnlyTheLatestPartOfALongHistory() {
        let session = session()
        session.loadHistory((0..<(Session.historyLimit + 10)).map { .user("message \($0)") })

        #expect(session.items.count == Session.historyLimit + 1)
        #expect(session.items.first?.kind == .notice(.earlierHidden))
        #expect(session.items.last?.kind == .user("message \(Session.historyLimit + 9)"))
    }

    @Test func letsYouPickTheAccountAndForkOnlyBeforeItStarts() {
        let session = session()
        session.setAccount(configDirectory: URL(filePath: "/Users/ana/.claude-personal"), name: "ana@personal")
        session.setFork(true)

        #expect(session.accountName == "ana@personal")
        #expect(session.configuration.configDirectory?.path == "/Users/ana/.claude-personal")
        #expect(session.configuration.arguments.suffix(3) == ["--resume", "abc", "--fork-session"])

        session.apply(.exited(status: 0, message: ""))
        session.setAccount(configDirectory: nil, name: "other")
        #expect(session.accountName == "ana@personal")
    }

    @Test func continuesALiveSessionInAnotherAccount() throws {
        let live = Session(configuration: SessionConfiguration(directory: URL(filePath: "/work/app"), permissionMode: "acceptEdits"), accountName: "work")
        #expect(live.continuation(configDirectory: nil, accountName: "x", fork: false) == nil)

        live.apply(.sessionStarted(sessionID: "live-1", model: nil, permissionMode: nil, directory: "/work/app/.claude/worktrees/w1"))
        live.append(.user("Ship it"))
        live.apply(.assistant(messageID: "m", blocks: [.toolUse(id: "t", name: "Bash", input: .object([:]))]))
        let copy = try #require(live.continuation(configDirectory: URL(filePath: "/Users/ana/.claude-personal"), accountName: "personal", fork: true))
        let moved = try #require(live.continuation(configDirectory: URL(filePath: "/Users/ana/.claude-personal"), accountName: "personal", fork: false))

        #expect(!moved.configuration.fork)
        #expect(moved.configuration.arguments.suffix(2) == ["--resume", "live-1"])
        #expect(copy.status == .dormant)
        #expect(copy.accountName == "personal")
        #expect(copy.configuration.resume == "live-1")
        #expect(copy.configuration.fork)
        #expect(copy.configuration.permissionMode == "acceptEdits")
        #expect(copy.workingDirectory.path == "/work/app/.claude/worktrees/w1")
        #expect(copy.items.count == 2)
        #expect(copy.items.last.flatMap { item -> ToolCall.State? in
            if case .tool(let call) = item.kind { call.state } else { nil }
        } == .stopped)
    }

    @Test func keepsModelEffortAndModeForWhenItStarts() {
        let session = session()
        session.setModel("sonnet")
        session.setEffort("high")
        session.setPermissionMode("plan")

        #expect(session.selectedModel == "sonnet")
        #expect(session.effort == "high")
        #expect(session.permissionMode == "plan")
        let arguments = session.configuration.arguments
        #expect(arguments.contains(["--model", "sonnet"]))
        #expect(arguments.contains(["--effort", "high"]))
        #expect(arguments.contains(["--permission-mode", "plan"]))

        session.setEffort(nil)
        #expect(!session.configuration.arguments.contains("--effort"))
    }

    @Test func asksForAWorktreeOnlyForNewSessions() {
        let fresh = SessionConfiguration(directory: URL(filePath: "/work/app"), worktree: "w1")
        let resumed = SessionConfiguration(directory: URL(filePath: "/work/app"), resume: "abc", worktree: "w1")

        #expect(fresh.arguments.suffix(2) == ["--worktree", "w1"])
        #expect(!resumed.arguments.contains("--worktree"))
    }
}
