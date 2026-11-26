import Foundation

public struct HookEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case blockedPrompt, reprompted, feedback, message, failed
    }

    public let kind: Kind
    public let hook: String?
    public let text: String

    public init(kind: Kind, hook: String?, text: String) {
        self.kind = kind
        self.hook = hook
        self.text = text
    }
}

public struct TaskNotification: Sendable, Equatable {
    public let summary: String
    public let detail: String

    public static func parse(_ text: String) -> TaskNotification? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<task-notification>"),
              let summary = text.firstMatch(of: /<summary>([\s\S]*?)<\/summary>/)?.1 else { return nil }
        let detail = text.firstMatch(of: /<system-reminder>([\s\S]*?)<\/system-reminder>/)?.1
            ?? text.firstMatch(of: /<result>([\s\S]*?)<\/result>/)?.1
            ?? ""
        return TaskNotification(
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum Hooks {
    private static let reportedElsewhere: Set<String> = ["PreToolUse", "UserPromptSubmit", "Stop", "SubagentStop", "PermissionRequest"]

    static func blockReason(fromToolResult content: String) -> String? {
        guard let match = content.firstMatch(of: /^[A-Za-z]+(?::\S+)? hook error: ([\s\S]*)$/) else { return nil }
        return withoutScriptPath(String(match.1))
    }

    static func informational(_ message: JSONValue) -> HookEvent? {
        let content = message["content"]?.string ?? ""
        if let outcome = message["prompt_submit_outcome"], outcome["kind"]?.string == "blocked_by_hook" {
            let reason = outcome["reason"]?.string ?? blockedPrompt(content)?.reason ?? ""
            return HookEvent(kind: .blockedPrompt, hook: "UserPromptSubmit", text: withoutScriptPath(reason))
        }
        if let blocked = blockedPrompt(content) {
            return HookEvent(kind: .blockedPrompt, hook: "UserPromptSubmit", text: blocked.reason)
        }
        guard let match = content.firstMatch(of: /^([A-Za-z]+(?::\S+)?) says: ([\s\S]*)$/) else { return nil }
        return HookEvent(kind: .message, hook: String(match.1), text: trimmed(String(match.2)))
    }

    static func blockedPrompt(_ content: String) -> (reason: String, prompt: String?)? {
        guard let match = content.firstMatch(of: /^UserPromptSubmit operation blocked by hook:\n([\s\S]*?)(?:\n+Original prompt: ([\s\S]*))?$/) else { return nil }
        return (withoutScriptPath(String(match.1)), match.2.map { trimmed(String($0)) })
    }

    static func reprompt(fromUserText text: String) -> HookEvent? {
        guard let match = text.firstMatch(of: /^([A-Za-z]+) hook feedback:\n([\s\S]*)$/) else { return nil }
        return HookEvent(kind: .reprompted, hook: String(match.1), text: trimmed(String(match.2)))
    }

    static func response(_ message: JSONValue) -> HookEvent? {
        let hook = message["hook_name"]?.string
        let event = message["hook_event"]?.string ?? ""
        let stderr = trimmed(message["stderr"]?.string ?? "")
        switch message["outcome"]?.string {
        case "success":
            let output = message["stdout"]?.string.flatMap(json)
            if event.hasPrefix("PostToolUse"), output?["decision"]?.string == "block" {
                return HookEvent(kind: .feedback, hook: hook, text: trimmed(output?["reason"]?.string ?? ""))
            }
            if event == "SessionStart", let text = output?["systemMessage"]?.string {
                return HookEvent(kind: .message, hook: hook, text: trimmed(text))
            }
            return nil
        case "error":
            guard message["exit_code"]?.number == 2 else { return HookEvent(kind: .failed, hook: hook, text: stderr) }
            if reportedElsewhere.contains(event) {
                return nil
            }
            return HookEvent(kind: event.hasPrefix("PostToolUse") ? .feedback : .failed, hook: hook, text: stderr)
        default:
            return nil
        }
    }

    static func attachment(_ attachment: JSONValue) -> HookEvent? {
        let hook = attachment["hookName"]?.string
        switch attachment["type"]?.string {
        case "hook_system_message":
            return attachment["content"]?.string.map { HookEvent(kind: .message, hook: hook, text: trimmed($0)) }
        case "hook_non_blocking_error":
            let stderr = attachment["stderr"]?.string ?? ""
            let text = stderr.firstMatch(of: /^Failed with non-blocking status code: ([\s\S]*)$/).map { String($0.1) } ?? stderr
            return HookEvent(kind: .failed, hook: hook, text: trimmed(text))
        case "hook_blocking_error":
            guard attachment["hookEvent"]?.string?.hasPrefix("PostToolUse") == true,
                  let text = attachment["blockingError"]?["blockingError"]?.string else { return nil }
            return HookEvent(kind: .feedback, hook: hook, text: trimmed(text))
        default:
            return nil
        }
    }

    private static func withoutScriptPath(_ text: String) -> String {
        trimmed(text.replacing(#/^\[[^\]\n]*\]: /#, with: ""))
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func json(_ text: String) -> JSONValue? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))).map(JSONValue.init)
    }
}
