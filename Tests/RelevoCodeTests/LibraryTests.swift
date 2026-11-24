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

    @Test func readsDesktopsSessionsByTheirCLIIdentifier() throws {
        let root = try temporaryFolder()
        let folder = root.appending(path: "account/org")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"cliSessionId":"abc","title":"Dependabot alerts","isArchived":false}"#.write(to: folder.appending(path: "local_1.json"), atomically: true, encoding: .utf8)
        try #"{"cliSessionId":"def","isArchived":true}"#.write(to: folder.appending(path: "local_2.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appending(path: "other.json"), atomically: true, encoding: .utf8)

        let sessions = SessionLibrary.desktopSessions(in: root)
        #expect(sessions["abc"] == DesktopSession(title: "Dependabot alerts", isArchived: false))
        #expect(sessions["def"]?.isArchived == true)
        #expect(sessions.count == 2)
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

    @Test func continuesALiveSessionInAnotherAccountAsACopy() throws {
        let live = Session(configuration: SessionConfiguration(directory: URL(filePath: "/work/app"), permissionMode: "acceptEdits"), accountName: "work")
        #expect(live.continuation(configDirectory: nil, accountName: "x") == nil)

        live.apply(.sessionStarted(sessionID: "live-1", model: nil, permissionMode: nil, directory: "/work/app/.claude/worktrees/w1"))
        live.append(.user("Ship it"))
        live.apply(.assistant(messageID: "m", blocks: [.toolUse(id: "t", name: "Bash", input: .object([:]))]))
        let copy = try #require(live.continuation(configDirectory: URL(filePath: "/Users/ana/.claude-personal"), accountName: "personal"))

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
