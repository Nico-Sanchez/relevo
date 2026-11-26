import Foundation

public struct AccountInfo: Sendable, Equatable {
    public let email: String?
    public let organization: String?
    public let subscription: String?
}

public struct ModelOption: Sendable, Equatable, Identifiable, Codable {
    public let value: String
    public let displayName: String
    public let description: String?
    public let effortLevels: [String]
    public let resolvedModel: String?

    public init(value: String, displayName: String, description: String?, effortLevels: [String], resolvedModel: String? = nil) {
        self.value = value
        self.displayName = displayName
        self.description = description
        self.effortLevels = effortLevels
        self.resolvedModel = resolvedModel
    }

    public var id: String { value }
}

public struct AppliedSettings: Sendable, Equatable {
    public let model: String?
    public let effort: String?

    public init(model: String?, effort: String?) {
        self.model = model
        self.effort = effort
    }
}

public struct SessionInfo: Sendable, Equatable {
    public let account: AccountInfo?
    public let models: [ModelOption]
    public let permissionMode: String?
    public let version: String?
}

public struct PermissionRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let toolName: String
    public let displayName: String
    public let input: JSONValue
    public let description: String?
    public let suggestions: [JSONValue]
    public let toolUseID: String?
    public var hookReason: String? = nil

    public var allowsEditsForSession: Bool {
        suggestions.contains { $0["type"]?.string == "setMode" && $0["mode"]?.string == "acceptEdits" }
    }

    public var questions: [Question]? {
        guard toolName == "AskUserQuestion", let questions = input["questions"]?.array else { return nil }
        let parsed = questions.compactMap(Question.init)
        return parsed.isEmpty ? nil : parsed
    }
}

public struct Question: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let description: String?
    }

    public let question: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool

    init?(_ value: JSONValue) {
        guard let question = value["question"]?.string else { return nil }
        self.question = question
        header = value["header"]?.string
        options = (value["options"]?.array ?? []).compactMap { option in
            option["label"]?.string.map { Option(label: $0, description: option["description"]?.string) }
        }
        multiSelect = value["multiSelect"]?.bool ?? false
    }

    public func answer(choosing labels: Set<String>, other: String?) -> String? {
        let chosen = options.map(\.label).filter(labels.contains)
        let written = other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = multiSelect ? chosen + [written] : [written.isEmpty ? chosen.first ?? "" : written]
        let answer = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        return answer.isEmpty ? nil : answer
    }
}

public struct RunningTask: Sendable, Equatable, Identifiable {
    public let id: String
    public let description: String
    public let kind: String?

    public init(id: String, description: String, kind: String?) {
        self.id = id
        self.description = description
        self.kind = kind
    }
}

public struct DiffHunk: Sendable, Equatable {
    public let oldStart: Int
    public let newStart: Int
    public let lines: [String]
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case thinking
    case toolUse(id: String, name: String, input: JSONValue)
}

public struct UsageWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let utilization: Double
    public let resetsAt: Date?
}

public struct TurnResult: Sendable, Equatable {
    public let isError: Bool
    public let text: String?
    public let costUSD: Double?
    public let durationMS: Double?
}

public enum Incoming: Sendable, Equatable {
    case controlResponse(requestID: String, success: Bool, payload: JSONValue)
    case sessionStarted(sessionID: String, model: String?, permissionMode: String?, directory: String?)
    case status(String?)
    case taskSummary(String?)
    case textStarted(messageID: String, index: Int)
    case textDelta(messageID: String, index: Int, text: String)
    case thinkingStarted
    case assistant(messageID: String, blocks: [ContentBlock])
    case toolResult(toolUseID: String, content: String, isError: Bool, patch: [DiffHunk])
    case permissionRequest(PermissionRequest)
    case usage([UsageWindow])
    case backgroundTasks([RunningTask])
    case hook(HookEvent)
    case hookStarted(id: String, name: String)
    case hookFinished(id: String, event: HookEvent?)
    case result(TurnResult)
    case exited(status: Int32, message: String)
    case ignored
}

public enum Wire {
    public static func parse(_ line: Substring) -> Incoming {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return .ignored }
        return parse(JSONValue(object))
    }

    static func parse(_ message: JSONValue) -> Incoming {
        switch message["type"]?.string {
        case "control_response":
            guard let response = message["response"], let id = response["request_id"]?.string else { return .ignored }
            let success = response["subtype"]?.string == "success"
            return .controlResponse(requestID: id, success: success, payload: success ? response["response"] ?? .null : response["error"] ?? .null)
        case "control_request":
            return permission(message)
        case "system":
            return system(message)
        case "stream_event":
            return stream(message)
        case "assistant":
            guard let content = message["message"]?["content"]?.array,
                  let id = message["message"]?["id"]?.string else { return .ignored }
            return .assistant(messageID: id, blocks: content.compactMap(block))
        case "user":
            let result = toolResult(message)
            guard result == .ignored, message["isSynthetic"]?.bool == true || message["isMeta"]?.bool == true,
                  let text = History.userText(message["message"]?["content"]),
                  let event = Hooks.reprompt(fromUserText: text) else { return result }
            return .hook(event)
        case "rate_limit_event":
            return usage(message["rate_limit_info"]?["unifiedWindows"])
        case "result":
            return .result(TurnResult(
                isError: message["is_error"]?.bool ?? (message["subtype"]?.string != "success"),
                text: message["result"]?.string,
                costUSD: message["total_cost_usd"]?.number,
                durationMS: message["duration_ms"]?.number
            ))
        default:
            return .ignored
        }
    }

    public static func appliedSettings(from payload: JSONValue) -> AppliedSettings? {
        guard let applied = payload["applied"] else { return nil }
        return AppliedSettings(model: applied["model"]?.string, effort: applied["effort"]?.string)
    }

    public static func sessionInfo(from payload: JSONValue) -> SessionInfo {
        let account = payload["account"].map {
            AccountInfo(email: $0["email"]?.string, organization: $0["organization"]?.string, subscription: $0["subscriptionType"]?.string)
        }
        let models = (payload["models"]?.array ?? []).compactMap { model -> ModelOption? in
            guard let value = model["value"]?.string else { return nil }
            return ModelOption(
                value: value,
                displayName: model["displayName"]?.string ?? value,
                description: model["description"]?.string,
                effortLevels: (model["supportedEffortLevels"]?.array ?? []).compactMap(\.string),
                resolvedModel: model["resolvedModel"]?.string
            )
        }
        return SessionInfo(
            account: account,
            models: models,
            permissionMode: payload["current_permission_mode"]?.string,
            version: payload["claude_code_version"]?.string
        )
    }

    private static func permission(_ message: JSONValue) -> Incoming {
        guard let id = message["request_id"]?.string, let request = message["request"],
              request["subtype"]?.string == "can_use_tool", let tool = request["tool_name"]?.string else { return .ignored }
        return .permissionRequest(PermissionRequest(
            id: id,
            toolName: tool,
            displayName: request["display_name"]?.string ?? tool,
            input: request["input"] ?? .object([:]),
            description: request["description"]?.string,
            suggestions: request["permission_suggestions"]?.array ?? [],
            toolUseID: request["tool_use_id"]?.string,
            hookReason: request["decision_reason_type"]?.string == "hook" ? request["decision_reason"]?.string : nil
        ))
    }

    private static func system(_ message: JSONValue) -> Incoming {
        switch message["subtype"]?.string {
        case "init":
            guard let id = message["session_id"]?.string else { return .ignored }
            return .sessionStarted(
                sessionID: id, model: message["model"]?.string, permissionMode: message["permissionMode"]?.string,
                directory: message["cwd"]?.string
            )
        case "status":
            return .status(message["status"]?.string)
        case "task_summary":
            return .taskSummary(message["detail"]?.string)
        case "background_tasks_changed":
            return .backgroundTasks((message["tasks"]?.array ?? []).compactMap { task in
                guard let id = task["task_id"]?.string else { return nil }
                return RunningTask(id: id, description: task["description"]?.string ?? id, kind: task["task_type"]?.string)
            })
        case "informational":
            return Hooks.informational(message).map(Incoming.hook) ?? .ignored
        case "hook_started":
            guard let id = message["hook_id"]?.string else { return .ignored }
            return .hookStarted(id: id, name: message["hook_name"]?.string ?? message["hook_event"]?.string ?? "")
        case "hook_response":
            guard let id = message["hook_id"]?.string else { return .ignored }
            return .hookFinished(id: id, event: Hooks.response(message))
        default:
            return .ignored
        }
    }

    private static func stream(_ message: JSONValue) -> Incoming {
        guard let event = message["event"], let messageID = message["api_message_id"]?.string else { return .ignored }
        let index = Int(event["index"]?.number ?? 0)
        switch event["type"]?.string {
        case "content_block_start":
            switch event["content_block"]?["type"]?.string {
            case "text": return .textStarted(messageID: messageID, index: index)
            case "thinking": return .thinkingStarted
            default: return .ignored
            }
        case "content_block_delta":
            guard event["delta"]?["type"]?.string == "text_delta", let text = event["delta"]?["text"]?.string else { return .ignored }
            return .textDelta(messageID: messageID, index: index, text: text)
        default:
            return .ignored
        }
    }

    private static func block(_ block: JSONValue) -> ContentBlock? {
        switch block["type"]?.string {
        case "text": block["text"]?.string.map(ContentBlock.text)
        case "thinking": .thinking
        case "tool_use":
            block["id"]?.string.flatMap { id in
                block["name"]?.string.map { .toolUse(id: id, name: $0, input: block["input"] ?? .object([:])) }
            }
        default: nil
        }
    }

    private static func toolResult(_ message: JSONValue) -> Incoming {
        guard let first = message["message"]?["content"]?.array?.first(where: { $0["type"]?.string == "tool_result" }),
              let id = first["tool_use_id"]?.string else { return .ignored }
        let content: String
        switch first["content"] {
        case .string(let text): content = text
        case .array(let parts): content = parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
        default: content = ""
        }
        let structured = message["tool_use_result"] ?? message["toolUseResult"]
        let patch = (structured?["structuredPatch"]?.array ?? []).map { hunk in
            DiffHunk(
                oldStart: Int(hunk["oldStart"]?.number ?? 0),
                newStart: Int(hunk["newStart"]?.number ?? 0),
                lines: (hunk["lines"]?.array ?? []).compactMap(\.string)
            )
        }
        return .toolResult(toolUseID: id, content: content, isError: first["is_error"]?.bool ?? false, patch: patch)
    }

    private static func usage(_ windows: JSONValue?) -> Incoming {
        guard case .object(let values)? = windows else { return .ignored }
        let parsed = values.compactMap { id, window -> UsageWindow? in
            guard let utilization = window["utilization"]?.number else { return nil }
            return UsageWindow(id: id, utilization: utilization * 100, resetsAt: window["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) })
        }
        return .usage(parsed.sorted { $0.id < $1.id })
    }

    public static func userMessage(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull(), "session_id": "default"]
    }

    public static func controlRequest(id: String, _ request: [String: Any]) -> [String: Any] {
        ["type": "control_request", "request_id": id, "request": request]
    }

    public static func permissionResponse(to request: PermissionRequest, decision: PermissionDecision) -> [String: Any] {
        var response: [String: Any]
        switch decision {
        case .allow:
            response = ["behavior": "allow", "updatedInput": request.input.any]
        case .allowEditsForSession:
            response = [
                "behavior": "allow",
                "updatedInput": request.input.any,
                "updatedPermissions": request.suggestions.filter { $0["type"]?.string == "setMode" }.map(\.any),
            ]
        case .answer(let answers):
            var input = request.input
            if case .object(var fields) = input {
                fields["answers"] = .object(answers.mapValues(JSONValue.string))
                input = .object(fields)
            }
            response = ["behavior": "allow", "updatedInput": input.any]
        case .deny(let reason):
            response = ["behavior": "deny", "message": reason]
        }
        return ["type": "control_response", "response": ["subtype": "success", "request_id": request.id, "response": response]]
    }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case allowEditsForSession
    case answer([String: String])
    case deny(String)
}
