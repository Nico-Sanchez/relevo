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
