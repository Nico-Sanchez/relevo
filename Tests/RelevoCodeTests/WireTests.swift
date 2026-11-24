import Foundation
import Testing
@testable import RelevoCode

func event(_ json: String) -> Incoming {
    Wire.parse(Substring(json))
}

let initializeResponse = #"""
    {"type":"control_response","response":{"subtype":"success","request_id":"relevo_1","response":{"account":{"email":"ana@example.com","organization":"Ana's Organization","subscriptionType":"Claude Pro"},"models":[{"value":"default","displayName":"Default (recommended)","description":"Opus 5.5","supportedEffortLevels":["low","medium","high"]},{"value":"sonnet","displayName":"Sonnet"}],"current_permission_mode":"default","claude_code_version":"2.1.331"}}}
    """#

let permissionLine = #"""
    {"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/tmp/x/hello.txt","content":"hi"},"description":"hello.txt","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_1"}}
    """#

let toolUseLine = #"""
    {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Write","input":{"file_path":"/tmp/x/hello.txt","content":"hi"}}]},"session_id":"s1"}
    """#

let toolResultLine = #"""
    {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"File created successfully"}]},"tool_use_result":{"type":"update","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-hello","+hi"]}]}}
    """#

@Suite struct WireTests {
    @Test func readsTheAccountAndModelsFromInitialize() throws {
        guard case .controlResponse(let id, let success, let payload) = event(initializeResponse) else {
            Issue.record("not a control response")
            return
        }
        let info = Wire.sessionInfo(from: payload)

        #expect(id == "relevo_1")
        #expect(success)
        #expect(info.account == AccountInfo(email: "ana@example.com", organization: "Ana's Organization", subscription: "Claude Pro"))
        #expect(info.models.map(\.value) == ["default", "sonnet"])
        #expect(info.models.first?.effortLevels == ["low", "medium", "high"])
        #expect(info.permissionMode == "default")
    }

    @Test func readsAPermissionRequest() {
        guard case .permissionRequest(let request) = event(permissionLine) else {
            Issue.record("not a permission request")
            return
        }

        #expect(request.id == "perm-1")
        #expect(request.toolName == "Write")
        #expect(request.description == "hello.txt")
        #expect(request.input["content"]?.string == "hi")
        #expect(request.toolUseID == "toolu_1")
        #expect(request.allowsEditsForSession)
    }

    @Test func readsStreamingTextAndFinishedBlocks() {
        #expect(event(#"{"type":"stream_event","api_message_id":"msg_2","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}"#)
            == .textStarted(messageID: "msg_2", index: 1))
        #expect(event(#"{"type":"stream_event","api_message_id":"msg_2","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"do"}}}"#)
            == .textDelta(messageID: "msg_2", index: 1, text: "do"))
        #expect(event(#"{"type":"stream_event","api_message_id":"msg_2","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}}}"#) == .ignored)
        #expect(event(toolUseLine) == .assistant(messageID: "msg_1", blocks: [
            .toolUse(id: "toolu_1", name: "Write", input: .object(["file_path": .string("/tmp/x/hello.txt"), "content": .string("hi")])),
        ]))
    }

    @Test func readsToolResultsWithTheirPatch() {
        #expect(event(toolResultLine) == .toolResult(
            toolUseID: "toolu_1", content: "File created successfully", isError: false,
            patch: [DiffHunk(oldStart: 1, newStart: 1, lines: ["-hello", "+hi"])]
        ))
        let failed = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_2","type":"tool_result","is_error":true,"content":[{"type":"text","text":"boom"}]}]}}"#
        #expect(event(failed) == .toolResult(toolUseID: "toolu_2", content: "boom", isError: true, patch: []))
    }

    @Test func readsSessionStatusUsageAndResults() {
        #expect(event(#"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-5-5","permissionMode":"default"}"#)
            == .sessionStarted(sessionID: "s1", model: "claude-opus-5-5", permissionMode: "default", directory: nil))
        #expect(event(#"{"type":"system","subtype":"task_summary","detail":"Writing hello.txt"}"#) == .taskSummary("Writing hello.txt"))
        #expect(event(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.02,"resetsAt":1795986000},"five_hour":{"utilization":0.12,"resetsAt":1795497000}}}}"#)
            == .usage([
                UsageWindow(id: "five_hour", utilization: 12, resetsAt: Date(timeIntervalSince1970: 1795497000)),
                UsageWindow(id: "seven_day", utilization: 2, resetsAt: Date(timeIntervalSince1970: 1795986000)),
            ]))
        #expect(event(#"{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.34,"duration_ms":10241}"#)
            == .result(TurnResult(isError: false, text: "done", costUSD: 0.34, durationMS: 10241)))
        #expect(event(#"{"type":"system","subtype":"hook_started"}"#) == .ignored)
        #expect(event("not json") == .ignored)
    }

    @Test func answersPermissionRequestsTheWayTheCLIExpects() throws {
        guard case .permissionRequest(let request) = event(permissionLine) else { return }

        let allow = try #require(Wire.permissionResponse(to: request, decision: .allow)["response"] as? [String: Any])
        #expect(allow["request_id"] as? String == "perm-1")
        #expect(allow["subtype"] as? String == "success")
        let allowed = try #require(allow["response"] as? [String: Any])
        #expect(allowed["behavior"] as? String == "allow")
        #expect((allowed["updatedInput"] as? [String: Any])?["content"] as? String == "hi")

        let session = try #require((Wire.permissionResponse(to: request, decision: .allowEditsForSession)["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect((session["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String == "acceptEdits")

        let deny = try #require((Wire.permissionResponse(to: request, decision: .deny("No"))["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(deny["behavior"] as? String == "deny")
        #expect(deny["message"] as? String == "No")
    }

    @Test func buildsTheCommandLineForEachSession() {
        let directory = URL(filePath: "/tmp/project")
        let plain = SessionConfiguration(directory: directory)
        #expect(plain.arguments.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json"]))
        #expect(plain.arguments.contains("--permission-prompt-tool"))
        #expect(!plain.arguments.contains("--resume"))
        #expect(plain.environment(base: ["CLAUDE_CONFIG_DIR": "/elsewhere", "PATH": "/bin"]) == ["PATH": "/bin"])

        let resumed = SessionConfiguration(
            directory: directory, configDirectory: URL(filePath: "/Users/ana/.claude-work"), resume: "abc", fork: true,
            model: "sonnet", permissionMode: "bypassPermissions"
        )
        #expect(Array(resumed.arguments.suffix(8)) == [
            "--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions",
            "--model", "sonnet", "--resume", "abc", "--fork-session",
        ])
        #expect(resumed.environment(base: [:])["CLAUDE_CONFIG_DIR"] == "/Users/ana/.claude-work")
    }

    @Test func jsonValuesSurviveARoundTrip() throws {
        let original: [String: Any] = ["a": 1, "b": [true, "x", NSNull()], "c": ["d": 2.5]]
        let value = JSONValue(original)
        let data = try JSONSerialization.data(withJSONObject: value.any, options: .sortedKeys)

        #expect(String(decoding: data, as: UTF8.self) == #"{"a":1,"b":[true,"x",null],"c":{"d":2.5}}"#)
        #expect(value["b"]?.array?.first == .bool(true))
    }
}
