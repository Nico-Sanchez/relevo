import Foundation
import Testing
@testable import RelevoCode

private func history(_ lines: [String]) -> [HistoryEntry] {
    History.entries(from: lines.compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))).map(JSONValue.init)
    })
}

@Suite struct HookWireTests {
    @Test func asksTheCLIForHookEvents() {
        #expect(SessionConfiguration(directory: URL(filePath: "/work/app")).arguments.contains("--include-hook-events"))
    }

    @Test func readsAPromptBlockedByAHook() {
        let line = #"""
            {"type":"system","subtype":"informational","content":"UserPromptSubmit operation blocked by hook:\n[/x/prompt.sh]: stderr says no\n\n\nOriginal prompt: STDERRBLOCK say hi","level":"warning","prevent_continuation":true,"prompt_submit_outcome":{"kind":"blocked_by_hook","prompt_kept":false,"reason":"stderr says no"}}
            """#

        #expect(event(line) == .hook(HookEvent(kind: .blockedPrompt, hook: "UserPromptSubmit", text: "stderr says no")))
    }

    @Test func readsAMessageAHookShowsTheUser() {
        let line = #"""
            {"type":"system","subtype":"informational","content":"PostToolUse:Bash says: hub: #4913 (In progress → In review)","level":"notice"}
            """#

        #expect(event(line) == .hook(HookEvent(kind: .message, hook: "PostToolUse:Bash", text: "hub: #4913 (In progress → In review)")))
        #expect(event(#"{"type":"system","subtype":"informational","content":"Compacted using a summary written while you worked"}"#) == .ignored)
    }

    @Test func readsAStopHookThatSendsClaudeBack() {
        let line = #"""
            {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Stop hook feedback:\nBefore finishing, run the tests"}]},"parent_tool_use_id":null,"isSynthetic":true}
            """#

        #expect(event(line) == .hook(HookEvent(kind: .reprompted, hook: "Stop", text: "Before finishing, run the tests")))
    }

    @Test func readsHookRunsAndWhatTheyReport() {
        func response(_ fields: String) -> Incoming {
            event(#"{"type":"system","subtype":"hook_response","hook_id":"h1","hook_name":"PostToolUse:Bash","hook_event":"PostToolUse","# + fields + "}")
        }

        #expect(event(#"{"type":"system","subtype":"hook_started","hook_id":"h1","hook_name":"Stop","hook_event":"Stop"}"#) == .hookStarted(id: "h1", name: "Stop"))
        #expect(response(#""stdout":"","stderr":"","exit_code":0,"outcome":"success""#) == .hookFinished(id: "h1", event: nil))
        #expect(response(#""stdout":"","stderr":"post hook crashed\n","exit_code":1,"outcome":"error""#)
            == .hookFinished(id: "h1", event: HookEvent(kind: .failed, hook: "PostToolUse:Bash", text: "post hook crashed")))
        #expect(response(#""stdout":"","stderr":"Found 1 issue\n","exit_code":2,"outcome":"error""#)
            == .hookFinished(id: "h1", event: HookEvent(kind: .feedback, hook: "PostToolUse:Bash", text: "Found 1 issue")))
        #expect(event(#"{"type":"system","subtype":"hook_response","hook_id":"h2","hook_name":"PreToolUse:Bash","hook_event":"PreToolUse","stderr":"no","exit_code":2,"outcome":"error"}"#)
            == .hookFinished(id: "h2", event: nil))
        #expect(event(#"{"type":"system","subtype":"hook_response","hook_id":"h3","hook_name":"SessionStart:startup","hook_event":"SessionStart","stdout":"{\"systemMessage\":\"Welcome back\"}\n","stderr":"","exit_code":0,"outcome":"success"}"#)
            == .hookFinished(id: "h3", event: HookEvent(kind: .message, hook: "SessionStart:startup", text: "Welcome back")))
    }

    @Test func readsWhyAHookAsksForPermission() {
        let line = #"""
            {"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"gh pr create"},"decision_reason":"Link an issue first","decision_reason_type":"hook","decision_reason_hook_event":"PreToolUse","tool_use_id":"toolu_1"}}
            """#
        guard case .permissionRequest(let request) = event(line) else {
            Issue.record("not a permission request")
            return
        }

        #expect(request.hookReason == "Link an issue first")
        guard case .permissionRequest(let other) = event(permissionLine) else { return }
        #expect(other.hookReason == nil)
    }

    @Test func readsTaskNotifications() {
        let review = TaskNotification.parse("<task-notification>\n<summary>Security review found issues</summary>\n</task-notification>\n<system-reminder>\nAddress them: hardcoded token\n</system-reminder>")
        let agent = TaskNotification.parse("<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n<summary>Agent \"Review\" finished</summary>\n</task-notification>")

        #expect(review == TaskNotification(summary: "Security review found issues", detail: "Address them: hardcoded token"))
        #expect(agent == TaskNotification(summary: "Agent \"Review\" finished", detail: ""))
        #expect(TaskNotification.parse("Fix the login bug") == nil)
    }

    @Test func rebuildsHookOutcomesFromATranscript() {
        let entries = history([
            #"{"type":"attachment","attachment":{"type":"hook_non_blocking_error","hookName":"SessionStart:startup","hookEvent":"SessionStart","stderr":"Failed with non-blocking status code: no Python found","exitCode":1}}"#,
            #"{"type":"system","subtype":"informational","content":"UserPromptSubmit operation blocked by hook:\nPrompts with secrets are not allowed\n\nOriginal prompt: my token is abc","isMeta":false,"level":"warning"}"#,
            #"{"type":"user","message":{"role":"user","content":"Ship it"}}"#,
            #"{"type":"attachment","attachment":{"type":"hook_system_message","content":"hub: #12 moved","hookName":"PostToolUse:Bash","hookEvent":"PostToolUse"}}"#,
            #"{"type":"attachment","attachment":{"type":"hook_blocking_error","hookName":"PostToolUse:Edit","hookEvent":"PostToolUse","blockingError":{"blockingError":"Lint failed","command":"lint.sh"}}}"#,
            #"{"type":"attachment","attachment":{"type":"hook_blocking_error","hookName":"Stop","hookEvent":"Stop","blockingError":{"blockingError":"Run the tests","command":"stop.sh"}}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Stop hook feedback:\nRun the tests"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<summary>Security review found issues</summary>\n</task-notification>\n<system-reminder>\nToken in config.py\n</system-reminder>"},"origin":{"kind":"task-notification"}}"#,
            #"{"type":"attachment","attachment":{"type":"hook_success","hookName":"Stop","hookEvent":"Stop","stdout":""}}"#,
        ])

        #expect(entries == [
            .event(.hook(HookEvent(kind: .failed, hook: "SessionStart:startup", text: "no Python found"))),
            .user("my token is abc"),
            .event(.hook(HookEvent(kind: .blockedPrompt, hook: "UserPromptSubmit", text: "Prompts with secrets are not allowed"))),
            .user("Ship it"),
            .event(.hook(HookEvent(kind: .message, hook: "PostToolUse:Bash", text: "hub: #12 moved"))),
            .event(.hook(HookEvent(kind: .feedback, hook: "PostToolUse:Edit", text: "Lint failed"))),
            .event(.hook(HookEvent(kind: .reprompted, hook: "Stop", text: "Run the tests"))),
            .automated(summary: "Security review found issues", text: "Token in config.py"),
        ])
    }
}

@MainActor
@Suite struct HookSessionTests {
    func session() -> Session {
        let session = Session(configuration: SessionConfiguration(directory: URL(filePath: "/work/app")), accountName: "Ana")
        session.apply(.assistant(messageID: "m1", blocks: [
            .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("gh pr create")])),
            .toolUse(id: "t2", name: "Bash", input: .object(["command": .string("rm -rf build")])),
        ]))
        return session
    }

    var calls: (Session) -> [ToolCall] {
        { session in session.items.compactMap { if case .tool(let call) = $0.kind { call } else { nil } } }
    }

    @Test func marksAToolABlockedByAHookWithItsReason() {
        let session = session()
        session.apply(.toolResult(toolUseID: "t1", content: "PreToolUse:Bash hook error: [/Users/ana/.claude/hub/hub.py]: hub: link an issue first\n", isError: true, patch: []))
        session.apply(.toolResult(toolUseID: "t2", content: "PreToolUse:Bash hook error: rm is denied", isError: true, patch: []))

        #expect(calls(session).map(\.state) == [.blocked, .blocked])
        #expect(calls(session).map(\.result) == ["hub: link an issue first", "rm is denied"])
        #expect(ToolActivity.state(of: calls(session)) == .blocked)
    }

    @Test func listsEachBlockReasonOnceForAGroupOfTools() {
        let session = session()
        session.apply(.assistant(messageID: "m2", blocks: [.toolUse(id: "t3", name: "Bash", input: .object(["command": .string("gh pr create --draft")]))]))
        session.apply(.toolResult(toolUseID: "t1", content: "PreToolUse:Bash hook error: link an issue first", isError: true, patch: []))
        session.apply(.toolResult(toolUseID: "t2", content: "Exit code 1\nno such file", isError: true, patch: []))
        session.apply(.toolResult(toolUseID: "t3", content: "PreToolUse:Bash hook error: link an issue first", isError: true, patch: []))

        #expect(ToolActivity.blockReasons(of: calls(session)) == ["link an issue first"])
    }

    @Test func keepsOtherToolErrorsAsFailures() {
        let session = session()
        session.apply(.toolResult(toolUseID: "t1", content: "Exit code 1\nno such file", isError: true, patch: []))

        #expect(calls(session).first?.state == .failed)
    }

    @Test func showsWhichHookIsRunningUntilItFinishes() {
        let session = session()
        session.apply(.hookStarted(id: "h1", name: "Stop"))
        #expect(session.runningHook == "Stop")
        session.apply(.hookFinished(id: "h1", event: nil))
        #expect(session.runningHook == nil)

        session.apply(.hookStarted(id: "h2", name: "PostToolUse:Bash"))
        #expect(session.runningHook == nil)

        session.apply(.hookStarted(id: "h3", name: "UserPromptSubmit"))
        session.apply(.thinkingStarted)
        #expect(session.runningHook == nil)
    }

    @Test func reportsARepeatedHookFailureOncePerTurn() {
        let session = session()
        let failure = HookEvent(kind: .failed, hook: "PreToolUse:Bash", text: "You have not agreed to the Xcode license")
        session.apply(.hookFinished(id: "h1", event: failure))
        session.apply(.hookFinished(id: "h2", event: failure))
        session.apply(.hook(HookEvent(kind: .message, hook: "PostToolUse:Bash", text: "hub: #1 moved")))
        session.apply(.hook(HookEvent(kind: .message, hook: "PostToolUse:Bash", text: "hub: #1 moved")))

        let hooks = session.items.compactMap { if case .hook(let hook) = $0.kind { hook } else { nil } }
        #expect(hooks.map(\.kind) == [.failed, .message, .message])

        session.loadHistory([.user("Try again"), .event(.hook(failure))])
        #expect(session.items.contains { $0.kind == .hook(failure) })
    }
}
