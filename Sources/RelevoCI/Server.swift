import Foundation

public final class Server: @unchecked Sendable {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static let fallbackVersion = "2025-06-18"

    static let instructions = """
        relevo-ci watches the pull request of this session's branch. Its channel messages report CI failures, \
        new review feedback and merge conflicts; handle each one as the message says. Use the pr_context tool \
        to read the pull request's checks and feedback, and pr_watch to pause or resume these messages.
        """

    private let source: any PullRequestSource
    private let ignoredAuthors: Set<String>
    private let trustedAuthors: Set<String>
    private let send: @Sendable (Data) -> Void
    private let log: @Sendable (String) -> Void
    private let startWatching: @Sendable (Server) -> Void
    private let lock = NSLock()
    private var watch: Watch?
    private var paused = false
    private var started = false

    public init(
        source: any PullRequestSource,
        ignoredAuthors: Set<String> = [],
        trustedAuthors: Set<String> = [],
        send: @escaping @Sendable (Data) -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in },
        startWatching: @escaping @Sendable (Server) -> Void
    ) {
        self.source = source
        self.ignoredAuthors = ignoredAuthors
        self.trustedAuthors = trustedAuthors
        self.send = send
        self.log = log
        self.startWatching = startWatching
    }

    public func receive(_ line: String) {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let method = request["method"] as? String else { return }
        if method == "notifications/initialized" {
            let first = lock.withLock {
                defer { started = true }
                return !started
            }
            if first {
                startWatching(self)
            }
            return
        }
        guard let id = request["id"] else { return }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        do {
            reply["result"] = try result(of: method, params: request["params"] as? [String: Any] ?? [:])
        } catch let error as RequestError {
            reply["error"] = ["code": error.code, "message": error.message]
        } catch {
            reply["error"] = ["code": -32603, "message": String(describing: error)]
        }
        write(reply)
    }

    public func poll() {
        guard !lock.withLock({ paused }) else { return }
        do {
            let viewer = try lock.withLock({ watch }) == nil ? source.viewer() : nil
            let pullRequest = try source.pullRequest()
            let events = lock.withLock {
                if watch == nil, let viewer {
                    watch = Watch(viewer: viewer, ignoredAuthors: ignoredAuthors, trustedAuthors: trustedAuthors)
                }
                return watch?.events(for: pullRequest) ?? []
            }
            for event in events {
                notify(event)
            }
        } catch {
            log("poll failed: \(error)")
        }
    }

    private func notify(_ event: Event) {
        var logs: [String: String] = [:]
        if case .checksFailed(let pullRequest, let checks) = event {
            logs = failedLogs(of: checks, in: pullRequest)
        }
        let message = event.message(logs: logs)
        var params: [String: Any] = ["content": message.content]
        params["meta"] = message.meta
        write(["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": params])
        log("sent \(message.meta["kind"] ?? "event") for PR #\(event.pullRequest.number)")
    }

    private func failedLogs(of checks: [Check], in pullRequest: PullRequest) -> [String: String] {
        var logs: [String: String] = [:]
        for check in checks {
            do {
                logs[check.name] = try source.failedLog(of: check, in: pullRequest)
            } catch {
                log("could not read the log of \(check.name): \(error)")
            }
        }
        return logs
    }

    private func result(of method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.fallbackVersion,
                "capabilities": ["experimental": ["claude/channel": [String: Any]()], "tools": [String: Any]()],
                "serverInfo": ["name": "relevo-ci", "version": "0.1.0"],
                "instructions": Self.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            return try call(params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            throw RequestError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(_ tool: String, arguments: [String: Any]) throws -> [String: Any] {
        switch tool {
        case "pr_context":
            return text(try context(includeLogs: arguments["include_logs"] as? Bool ?? false))
        case "pr_watch":
            guard let enabled = arguments["enabled"] as? Bool else {
                return text("Pass enabled: true to resume the messages or false to pause them.", isError: true)
            }
            lock.withLock { paused = !enabled }
            return text(enabled ? "relevo-ci messages resumed." : "relevo-ci messages paused until pr_watch is called with enabled: true.")
        default:
            throw RequestError(code: -32602, message: "Unknown tool: \(tool)")
        }
    }

    private func context(includeLogs: Bool) throws -> String {
        guard let pullRequest = try source.pullRequest() else {
            return "The current branch has no pull request."
        }
        let failed = pullRequest.checks.filter { $0.outcome == .failed }
        let logs = includeLogs ? failedLogs(of: failed, in: pullRequest) : [:]
        let status = lock.withLock { paused } ? "Messages are paused." : "Messages are on."
        return pullRequest.summary(logs: logs) + "\n\n" + status
    }

    private func text(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        send(data + Data("\n".utf8))
    }

    static var tools: [[String: Any]] {
        [
            [
                "name": "pr_context",
                "description": "Show the pull request of this session's branch: state, mergeability, every check with its outcome, and the review feedback. Set include_logs to add the last lines of each failed check's log.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["include_logs": ["type": "boolean", "description": "Include the failed steps' log lines of failing checks."]],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "pr_watch",
                "description": "Pause or resume the channel messages about CI failures, review feedback and conflicts on this session's pull request.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["enabled": ["type": "boolean", "description": "true resumes the messages, false pauses them."]],
                    "required": ["enabled"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }
}

struct RequestError: Error {
    let code: Int
    let message: String
}
