import Foundation
import Testing
@testable import RelevoCode

@MainActor
@Suite struct SessionTests {
    func makeSession() -> Session {
        Session(configuration: SessionConfiguration(directory: URL(filePath: "/tmp/project")), accountName: "Ana")
    }

    func texts(_ session: Session) -> [String] {
        session.items.compactMap { item in
            if case .assistant(let text) = item.kind { text } else { nil }
        }
    }

    func tool(_ session: Session) -> ToolCall? {
        session.items.lazy.compactMap { item in
            if case .tool(let call) = item.kind { call } else { nil }
        }.first
    }

    @Test func becomesIdleWithTheAccountOnceInitialized() {
        let session = makeSession()
        #expect(session.status == .starting)
        #expect(session.beginInitialize() == "relevo_1")

        session.apply(event(initializeResponse.replacingOccurrences(of: "relevo_1", with: "other")))
        #expect(session.info == nil)
        #expect(session.status == .starting)

        session.apply(event(initializeResponse))
        #expect(session.info?.account?.email == "ana@example.com")
        #expect(session.status == .idle)
    }

    @Test func streamsTextIntoOneItemAndKeepsItWhenTheBlockFinishes() {
        let session = makeSession()

        session.apply(.textStarted(messageID: "m", index: 0))
        session.apply(.textDelta(messageID: "m", index: 0, text: "Hel"))
        session.apply(.textDelta(messageID: "m", index: 0, text: "lo"))
        #expect(texts(session) == ["Hello"])

        session.apply(.assistant(messageID: "m", blocks: [.text("Hello.")]))
        #expect(texts(session) == ["Hello."])

        session.apply(.assistant(messageID: "n", blocks: [.text("Unstreamed")]))
        #expect(texts(session) == ["Hello.", "Unstreamed"])
    }

    @Test func followsAToolCallThroughItsPermissionAndResult() {
        let session = makeSession()
        session.apply(.status("requesting"))
        #expect(session.status == .working)

        session.apply(event(toolUseLine))
        #expect(tool(session)?.state == .running)

        session.apply(event(permissionLine))
        #expect(session.status == .waitingForPermission)
        #expect(session.pendingPermissions.map(\.id) == ["perm-1"])
        #expect(tool(session)?.state == .awaitingPermission)
        session.apply(.status("requesting"))
        #expect(session.status == .waitingForPermission)

        session.respond(session.pendingPermissions[0], .allowEditsForSession)
        #expect(session.pendingPermissions.isEmpty)
        #expect(session.status == .working)
        #expect(session.permissionMode == "acceptEdits")
        #expect(tool(session)?.state == .running)

        session.apply(event(toolResultLine))
        #expect(tool(session)?.state == .done)
        #expect(tool(session)?.patch.first?.lines == ["-hello", "+hi"])

        session.apply(.result(TurnResult(isError: false, text: "done", costUSD: 0.34, durationMS: 10)))
        #expect(session.status == .idle)
        #expect(session.cost == 0.34)
        #expect(session.activity == nil)
    }

    @Test func aDeniedToolStaysDenied() {
        let session = makeSession()
        session.apply(event(toolUseLine))
        session.apply(event(permissionLine))

        session.respond(session.pendingPermissions[0], .deny("Not now"))
        session.apply(.toolResult(toolUseID: "toolu_1", content: "The user doesn't want to proceed", isError: true, patch: []))

        #expect(tool(session)?.state == .denied)
    }

    @Test func answeringAQuestionLetsTheTurnGoOn() throws {
        let session = makeSession()
        session.apply(event(#"""
        {"type":"control_request","request_id":"ask-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Color?","options":[{"label":"Red"}],"multiSelect":false}]},"tool_use_id":"toolu_q"}}
        """#))
        #expect(session.status == .waitingForPermission)
        let request = try #require(session.pendingPermissions.first)

        session.respond(request, .answer(["Color?": "Red"]))

        #expect(session.pendingPermissions.isEmpty)
        #expect(session.status == .working)
    }

    func fakeSession(title: String? = nil) throws -> (Session, URL) {
        let folder = try temporaryFolder()
        let log = folder.appending(path: "stdin.jsonl")
        let cli = folder.appending(path: "claude")
        try "#!/bin/sh\nexec cat > \"$RELEVO_FAKE_LOG\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let session = Session(
            configuration: SessionConfiguration(directory: folder), accountName: "Ana",
            environment: ["RELEVO_FAKE_LOG": log.path, "PATH": "/usr/bin:/bin"], executable: cli, title: title
        )
        session.start()
        return (session, log)
    }

    func sent(_ log: URL, count: Int) async throws -> [JSONValue] {
        var requests: [JSONValue] = []
        for _ in 0..<40 {
            requests = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))).map(JSONValue.init)
            } ?? []
            if requests.count >= count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return requests
    }

    @Test func asksTheCLIWhichModelAndEffortItApplies() async throws {
        let (session, log) = try fakeSession()
        defer { session.stop() }
        var ready: [SessionInfo] = []
        session.onReady = { ready.append($0) }

        session.apply(.controlResponse(requestID: "relevo_1", success: true, payload: JSONValue(["models": [["value": "opus", "displayName": "Opus 5.5"]]])))
        let afterInitialize = try await sent(log, count: 2)
        #expect(afterInitialize.compactMap { $0["request"]?["subtype"]?.string } == ["initialize", "get_settings"])
        #expect(ready.map(\.models.count) == [1])

        session.apply(.controlResponse(requestID: "relevo_2", success: true, payload: JSONValue(["applied": ["model": "claude-opus-5-5", "effort": "xhigh"]])))
        #expect(session.applied == AppliedSettings(model: "claude-opus-5-5", effort: "xhigh"))

        session.setModel("sonnet")
        session.apply(.controlResponse(requestID: "relevo_3", success: true, payload: .object([:])))
        let afterChange = try await sent(log, count: 4)
        #expect(afterChange.compactMap { $0["request"]?["subtype"]?.string } == ["initialize", "get_settings", "set_model", "get_settings"])
    }

    @Test func announcesOnlyTheFirstMessageOfAnUntitledSession() throws {
        let (session, _) = try fakeSession()
        defer { session.stop() }
        var announced: [String] = []
        session.onFirstMessage = { announced.append($0) }

        session.send("Me ayudas a setupear esto? https://thinkingmachines.ai/inkling-2-mini")
        #expect(session.title == "Me ayudas a setupear esto?")
        session.send("Also the docs")
        session.rename("Configurar Inkling 2 mini")

        #expect(announced == ["Me ayudas a setupear esto? https://thinkingmachines.ai/inkling-2-mini"])
        #expect(session.title == "Configurar Inkling 2 mini")

        let (resumed, _) = try fakeSession(title: "Login bug")
        defer { resumed.stop() }
        resumed.onFirstMessage = { announced.append($0) }
        resumed.send("Keep going")
        #expect(announced.count == 1)
    }

    @Test func takesMessagesWhileClaudeWorks() async throws {
        let (session, log) = try fakeSession()
        defer { session.stop() }

        session.send("Fix the build")
        #expect(session.status == .working)
        #expect(session.steering.isEmpty)

        session.send("Also update the changelog")
        #expect(session.status == .working)
        #expect(session.steering.count == 1)

        session.apply(event(permissionLine))
        session.send("Use the staging database")
        #expect(session.status == .waitingForPermission)
        #expect(session.steering.count == 2)

        session.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        #expect(session.steering.isEmpty)

        var sent: [String] = []
        for _ in 0..<40 {
            sent = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))).map(JSONValue.init)
            }.filter { $0["type"]?.string == "user" }.compactMap { $0["message"]?["content"]?.string } ?? []
            if sent.count == 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sent == ["Fix the build", "Also update the changelog", "Use the staging database"])

        session.apply(.exited(status: 0, message: ""))
        #expect(!session.acceptsMessages)
    }

    @Test func followsBackgroundTasksAndTheTurnsTheyStart() {
        let session = makeSession()
        var moments: [Session.Moment] = []
        session.onMoment = { moments.append($0) }
        let task = RunningTask(id: "b1", description: "Pull inkling-2-mini", kind: "local_bash")
        session.apply(.sessionStarted(sessionID: "s1", model: nil, permissionMode: nil, directory: nil))
        session.apply(.backgroundTasks([task]))
        session.apply(.result(TurnResult(isError: false, text: "started", costUSD: nil, durationMS: nil)))
        #expect(session.status == .idle)
        #expect(session.backgroundTasks == [task])

        session.apply(.backgroundTasks([]))
        session.apply(.sessionStarted(sessionID: "s1", model: nil, permissionMode: nil, directory: nil))
        #expect(session.status == .working)
        session.append(.assistant("The model is ready."))
        session.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))

        #expect(session.status == .idle)
        #expect(moments == [.finished(nil), .finished("The model is ready.")])

        session.apply(.backgroundTasks([task]))
        session.apply(.exited(status: 0, message: ""))
        #expect(session.backgroundTasks.isEmpty)
    }

    @Test func remembersWhenTheLastTurnEnded() {
        let session = makeSession()
        session.apply(.status("requesting"))
        #expect(session.lastTurnEnded == nil)

        let before = Date.now
        session.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        #expect(session.lastTurnEnded.map { $0 >= before } == true)
    }

    @Test func reportsFailedTurnsAndCrashes() {
        let session = makeSession()

        session.apply(.result(TurnResult(isError: true, text: "Overloaded", costUSD: nil, durationMS: nil)))
        #expect(session.items.last?.kind == .notice(.turnFailed("Overloaded")))

        session.apply(.exited(status: 1, message: "Not logged in"))
        #expect(session.status == .ended(.exited(status: 1, message: "Not logged in")))
        session.apply(.exited(status: 0, message: ""))
        #expect(session.status == .ended(nil))
    }

    @Test func titlesTheSessionWithTheFolderUntilTheFirstMessage() {
        let session = makeSession()
        #expect(session.title == "project")
    }
}
