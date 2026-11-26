import Foundation
import Observation

public struct ToolCall: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running, awaitingPermission, done, failed, denied, stopped
    }

    public let id: String
    public let name: String
    public var input: JSONValue
    public var state: State = .running
    public var result: String?
    public var patch: [DiffHunk] = []
}

public enum Notice: Sendable, Equatable {
    public enum Setting: String, Sendable {
        case model, effort, permissionMode
    }

    case compacted
    case earlierHidden
    case turnFailed(String?)
    case refused(Setting, String?)

    public var isError: Bool {
        switch self {
        case .compacted, .earlierHidden: false
        case .turnFailed, .refused: true
        }
    }
}

public enum EndReason: Sendable, Equatable {
    case notInstalled
    case couldNotStart(String)
    case exited(status: Int32, message: String)
}

public struct TranscriptItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case user(String)
        case assistant(String)
        case tool(ToolCall)
        case notice(Notice)
        case automated(summary: String, text: String)
    }

    public let id: String
    public var kind: Kind
}

@MainActor
@Observable
public final class Session: Identifiable {
    public enum Status: Equatable {
        case dormant, starting, idle, working, waitingForPermission, ended(EndReason?)
    }

    public static let historyLimit = 400

    public let id = UUID()
    public private(set) var configuration: SessionConfiguration
    public private(set) var accountName: String
    public private(set) var workingDirectory: URL
    public private(set) var items: [TranscriptItem] = []
    public private(set) var status: Status
    public private(set) var info: SessionInfo?
    public private(set) var sessionID: String?
    public private(set) var model: String?
    public private(set) var permissionMode: String
    public private(set) var pendingPermissions: [PermissionRequest] = []
    public private(set) var activity: String?
    public private(set) var isThinking = false
    public private(set) var usage: [UsageWindow] = []
    public private(set) var cost: Double = 0
    public private(set) var customTitle: String?
    public private(set) var selectedModel: String?
    public private(set) var effort: String?
    @ObservationIgnored public var onUsage: (([UsageWindow]) -> Void)?

    private let environment: [String: String]
    private let executable: URL?
    private var process: ClaudeProcess?
    private var streamingText: [String: [Int]] = [:]
    private var finalizedText: [String: Int] = [:]
    private var toolIndex: [String: Int] = [:]
    private var requests = 0
    private var initializeID: String?
    private var changes: [String: Notice.Setting] = [:]

    public init(
        configuration: SessionConfiguration, accountName: String,
        environment: [String: String] = [:], executable: URL? = nil,
        title: String? = nil, transcript: [TranscriptItem] = [], dormant: Bool = false
    ) {
        self.configuration = configuration
        self.accountName = accountName
        self.environment = environment
        self.executable = executable
        self.permissionMode = configuration.permissionMode
        self.workingDirectory = configuration.directory
        self.customTitle = title
        self.sessionID = configuration.resume
        self.selectedModel = configuration.model
        self.effort = configuration.effort
        self.items = transcript
        self.status = dormant ? .dormant : .starting
    }

    public var title: String {
        if let customTitle {
            return customTitle
        }
        for item in items {
            if case .user(let text) = item.kind {
                return String(text.prefix(60))
            }
        }
        return workingDirectory.lastPathComponent
    }

    public var isBusy: Bool {
        status == .working || status == .waitingForPermission
    }

    public var canSend: Bool {
        status == .idle || status == .dormant
    }

    public func loadHistory(_ entries: [HistoryEntry]) {
        for entry in entries {
            switch entry {
            case .user(let text): append(.user(text))
            case .event(let event): apply(event)
            case .compacted: append(.notice(.compacted))
            }
        }
        for index in items.indices {
            if case .tool(var call) = items[index].kind, call.state == .running || call.state == .awaitingPermission {
                call.state = .stopped
                items[index].kind = .tool(call)
            }
        }
        if items.count > Self.historyLimit {
            items = [TranscriptItem(id: UUID().uuidString, kind: .notice(.earlierHidden))]
                + items.suffix(Self.historyLimit)
        }
        streamingText = [:]
        finalizedText = [:]
        toolIndex = [:]
        pendingPermissions = []
        activity = nil
        isThinking = false
        cost = 0
        status = .dormant
    }

    public func setAccount(configDirectory: URL?, name: String) {
        guard status == .dormant else { return }
        configuration.configDirectory = configDirectory
        accountName = name
    }

    public func setFork(_ fork: Bool) {
        guard status == .dormant else { return }
        configuration.fork = fork
    }

    public func setModel(_ value: String?) {
        selectedModel = value
        if process == nil {
            configuration.model = value
        } else if let value {
            request(["subtype": "set_model", "model": value], changing: .model)
        }
    }

    public func setEffort(_ level: String?) {
        effort = level
        if process == nil {
            configuration.effort = level
        } else {
            request(["subtype": "apply_flag_settings", "settings": ["effortLevel": level.map { $0 as Any } ?? NSNull()]], changing: .effort)
        }
    }

    public func setPermissionMode(_ mode: String) {
        permissionMode = mode
        if process == nil {
            configuration.permissionMode = mode
        } else {
            request(["subtype": "set_permission_mode", "mode": mode], changing: .permissionMode)
        }
    }

    private func request(_ body: [String: Any], changing what: Notice.Setting) {
        let id = nextRequestID()
        changes[id] = what
        process?.send(Wire.controlRequest(id: id, body))
    }

    public func continuation(configDirectory: URL?, accountName: String) -> Session? {
        guard let sessionID else { return nil }
        let configuration = SessionConfiguration(
            directory: workingDirectory, configDirectory: configDirectory, resume: sessionID, fork: true,
            model: selectedModel, permissionMode: permissionMode, effort: effort
        )
        let stopped = items.map { item in
            guard case .tool(var call) = item.kind, call.state == .running || call.state == .awaitingPermission else { return item }
            call.state = .stopped
            return TranscriptItem(id: item.id, kind: .tool(call))
        }
        return Session(
            configuration: configuration, accountName: accountName, environment: environment, executable: executable,
            title: title, transcript: stopped, dormant: true
        )
    }

    public func start() {
        guard let executable else {
            status = .ended(.notInstalled)
            return
        }
        let process = ClaudeProcess(configuration: configuration, environment: environment, executable: executable)
        do {
            try process.start()
        } catch {
            status = .ended(.couldNotStart(error.localizedDescription))
            return
        }
        self.process = process
        status = .starting
        process.send(Wire.controlRequest(id: beginInitialize(), ["subtype": "initialize"]))
        Task { [weak self] in
            for await event in process.events {
                self?.apply(event)
            }
        }
    }

    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if status == .dormant {
            start()
        }
        guard let process else { return }
        append(.user(text))
        status = .working
        process.send(Wire.userMessage(text))
    }

    public func sendAutomated(_ text: String, summary: String) {
        if status == .dormant {
            start()
        }
        guard let process, canSendNow else { return }
        append(.automated(summary: summary, text: text))
        status = .working
        process.send(Wire.userMessage(text))
    }

    private var canSendNow: Bool {
        status == .idle || status == .starting
    }

    public func respond(_ request: PermissionRequest, _ decision: PermissionDecision) {
        process?.send(Wire.permissionResponse(to: request, decision: decision))
        pendingPermissions.removeAll { $0.id == request.id }
        if let toolUseID = request.toolUseID {
            updateTool(toolUseID) { call in
                if case .deny = decision {
                    call.state = .denied
                } else {
                    call.state = .running
                }
            }
        }
        if decision == .allowEditsForSession {
            permissionMode = "acceptEdits"
        }
        status = pendingPermissions.isEmpty ? .working : .waitingForPermission
    }

    public func interrupt() {
        guard isBusy else { return }
        for request in pendingPermissions {
            respond(request, .deny("The user interrupted."))
        }
        process?.send(Wire.controlRequest(id: nextRequestID(), ["subtype": "interrupt"]))
    }

    public func stop() {
        process?.terminate()
    }

    func apply(_ event: Incoming) {
        switch event {
        case .controlResponse(let requestID, let success, let payload):
            if let what = changes.removeValue(forKey: requestID), !success {
                append(.notice(.refused(what, payload.string)))
            }
            if requestID == initializeID {
                info = Wire.sessionInfo(from: payload)
                if let mode = info?.permissionMode {
                    permissionMode = mode
                }
                if status == .starting {
                    status = .idle
                }
            }
        case .sessionStarted(let id, let model, let mode, let directory):
            sessionID = id
            self.model = model ?? self.model
            if let mode {
                permissionMode = mode
            }
            if let directory {
                workingDirectory = URL(filePath: directory)
            }
        case .status(let value):
            if value == "requesting", status != .waitingForPermission {
                status = .working
            }
        case .taskSummary(let detail):
            activity = detail
        case .thinkingStarted:
            isThinking = true
        case .textStarted(let messageID, _):
            isThinking = false
            streamingText[messageID, default: []].append(append(.assistant("")))
        case .textDelta(let messageID, _, let text):
            guard let index = streamingText[messageID]?.last else {
                streamingText[messageID, default: []].append(append(.assistant(text)))
                return
            }
            if case .assistant(let current) = items[index].kind {
                items[index].kind = .assistant(current + text)
            }
        case .assistant(let messageID, let blocks):
            for block in blocks {
                switch block {
                case .text(let text):
                    finalizeText(text, in: messageID)
                case .toolUse(let id, let name, let input):
                    if toolIndex[id] == nil {
                        toolIndex[id] = append(.tool(ToolCall(id: id, name: name, input: input)))
                    }
                case .thinking:
                    break
                }
            }
        case .toolResult(let id, let content, let isError, let patch):
            updateTool(id) { call in
                call.result = content
                call.patch = patch
                if call.state != .denied {
                    call.state = isError ? .failed : .done
                }
            }
        case .permissionRequest(let request):
            pendingPermissions.append(request)
            status = .waitingForPermission
            if let toolUseID = request.toolUseID {
                updateTool(toolUseID) { $0.state = .awaitingPermission }
            }
        case .usage(let windows):
            usage = windows
            onUsage?(windows)
        case .result(let result):
            status = .idle
            activity = nil
            isThinking = false
            cost = result.costUSD ?? cost
            if result.isError {
                append(.notice(.turnFailed(result.text)))
            }
        case .exited(let code, let message):
            pendingPermissions = []
            activity = nil
            isThinking = false
            status = .ended(code == 0 ? nil : .exited(status: code, message: message))
        case .ignored:
            break
        }
    }

    func beginInitialize() -> String {
        let id = nextRequestID()
        initializeID = id
        return id
    }

    @discardableResult
    func append(_ kind: TranscriptItem.Kind) -> Int {
        items.append(TranscriptItem(id: UUID().uuidString, kind: kind))
        return items.count - 1
    }

    private func finalizeText(_ text: String, in messageID: String) {
        let done = finalizedText[messageID, default: 0]
        let streamed = streamingText[messageID] ?? []
        if done < streamed.count {
            items[streamed[done]].kind = .assistant(text)
        } else {
            streamingText[messageID, default: []].append(append(.assistant(text)))
        }
        finalizedText[messageID] = done + 1
    }

    private func updateTool(_ id: String, _ change: (inout ToolCall) -> Void) {
        guard let index = toolIndex[id], case .tool(var call) = items[index].kind else { return }
        change(&call)
        items[index].kind = .tool(call)
    }

    private func nextRequestID() -> String {
        requests += 1
        return "relevo_\(requests)"
    }
}
