import Foundation
import Observation

public struct ToolCall: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running, awaitingPermission, done, failed, blocked, denied, stopped
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
        case hook(HookEvent)
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

    public enum Moment: Sendable, Equatable {
        case needsYou(PermissionRequest)
        case finished(String?)
        case stopped(String?)
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
    public private(set) var lastTurnEnded: Date?
    public private(set) var steering: Set<String> = []
    public private(set) var backgroundTasks: [RunningTask] = []
    public private(set) var applied: AppliedSettings?
    public private(set) var runningHook: String?
    @ObservationIgnored public var onReady: ((SessionInfo) -> Void)?
    @ObservationIgnored public var onMoment: ((Moment) -> Void)?
    @ObservationIgnored public var onFirstMessage: ((String) -> Void)?

    private let environment: [String: String]
    private let executable: URL?
    private var process: ClaudeProcess?
    private var streamingText: [String: [Int]] = [:]
    private var finalizedText: [String: Int] = [:]
    private var toolIndex: [String: Int] = [:]
    private var requests = 0
    private var initializeID: String?
    private var settingsID: String?
    private var changes: [String: Notice.Setting] = [:]
    private var runningHookID: String?

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
                return SessionTitle.fallback(from: text)
            }
        }
        return workingDirectory.lastPathComponent
    }

    public func rename(_ title: String) {
        customTitle = title
    }

    public var lastReply: String? {
        for item in items.reversed() {
            if case .assistant(let text) = item.kind, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    public var isBusy: Bool {
        status == .working || status == .waitingForPermission
    }

    public var canSend: Bool {
        status == .idle || status == .dormant
    }

    public var acceptsMessages: Bool {
        if case .ended = status { false } else { true }
    }

    public func loadHistory(_ entries: [HistoryEntry]) {
        for entry in entries {
            switch entry {
            case .user(let text): append(.user(text))
            case .event(let event): apply(event)
            case .compacted: append(.notice(.compacted))
            case .automated(let summary, let text): append(.automated(summary: summary, text: text))
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

    public func continuation(configDirectory: URL?, accountName: String, fork: Bool) -> Session? {
        guard let sessionID else { return nil }
        let configuration = SessionConfiguration(
            directory: workingDirectory, configDirectory: configDirectory, resume: sessionID, fork: fork,
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
        let first = customTitle == nil && !items.contains { if case .user = $0.kind { true } else { false } }
        let index = append(.user(text))
        if first {
            onFirstMessage?(text)
        }
        if isBusy {
            steering.insert(items[index].id)
        } else {
            status = .working
        }
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
        case .hook, .hookStarted, .hookFinished, .controlResponse, .status, .taskSummary, .usage, .backgroundTasks, .ignored:
            break
        default:
            runningHook = nil
            runningHookID = nil
        }
        switch event {
        case .controlResponse(let requestID, let success, let payload):
            if let what = changes.removeValue(forKey: requestID) {
                if success {
                    refreshSettings()
                } else {
                    append(.notice(.refused(what, payload.string)))
                }
            }
            if requestID == settingsID, success {
                applied = Wire.appliedSettings(from: payload)
            }
            if requestID == initializeID {
                let info = Wire.sessionInfo(from: payload)
                self.info = info
                if let mode = info.permissionMode {
                    permissionMode = mode
                }
                if status == .starting {
                    status = .idle
                }
                onReady?(info)
                refreshSettings()
            }
        case .sessionStarted(let id, let model, let mode, let directory):
            if status == .idle {
                status = .working
            }
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
            let blocked = isError ? Hooks.blockReason(fromToolResult: content) : nil
            updateTool(id) { call in
                call.result = blocked ?? content
                call.patch = patch
                if call.state != .denied {
                    call.state = blocked != nil ? .blocked : isError ? .failed : .done
                }
            }
        case .hook(let hook):
            if hook.kind == .failed, reportedThisTurn(hook) {
                break
            }
            append(.hook(hook))
        case .hookStarted(let id, let name):
            if !name.hasPrefix("PostToolUse") {
                runningHookID = id
                runningHook = name
            }
        case .hookFinished(let id, let hook):
            if id == runningHookID {
                runningHookID = nil
                runningHook = nil
            }
            if let hook {
                apply(.hook(hook))
            }
        case .permissionRequest(let request):
            pendingPermissions.append(request)
            status = .waitingForPermission
            if let toolUseID = request.toolUseID {
                updateTool(toolUseID) { $0.state = .awaitingPermission }
            }
            onMoment?(.needsYou(request))
        case .usage(let windows):
            usage = windows
        case .backgroundTasks(let tasks):
            backgroundTasks = tasks
        case .result(let result):
            status = .idle
            lastTurnEnded = .now
            steering = []
            activity = nil
            isThinking = false
            cost = result.costUSD ?? cost
            if result.isError {
                append(.notice(.turnFailed(result.text)))
            }
            onMoment?(result.isError ? .stopped(result.text) : .finished(lastReply))
        case .exited(let code, let message):
            pendingPermissions = []
            steering = []
            backgroundTasks = []
            activity = nil
            isThinking = false
            lastTurnEnded = .now
            status = .ended(code == 0 ? nil : .exited(status: code, message: message))
            if code != 0 {
                onMoment?(.stopped(message))
            }
        case .ignored:
            break
        }
    }

    private func refreshSettings() {
        let id = nextRequestID()
        settingsID = id
        process?.send(Wire.controlRequest(id: id, ["subtype": "get_settings"]))
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

    private func reportedThisTurn(_ hook: HookEvent) -> Bool {
        for item in items.reversed() {
            switch item.kind {
            case .user: return false
            case .hook(let earlier) where earlier == hook: return true
            default: continue
            }
        }
        return false
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
