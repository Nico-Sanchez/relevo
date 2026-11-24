import Foundation

public struct PastSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let file: URL
    public let directory: URL
    public let title: String
    public let lastActivity: Date
    public let branch: String?
    public var awaitsAnswer = false

    public var projectName: String {
        guard let worktree = worktreeName else { return directory.lastPathComponent }
        return "\(repositoryName) · \(worktree)"
    }

    public var repositoryName: String {
        let parts = directory.pathComponents
        if let marker = worktreeMarker, marker >= 2 {
            return parts[marker - 2]
        }
        return directory.lastPathComponent
    }

    public var worktreeName: String? {
        guard let marker = worktreeMarker else { return nil }
        return directory.pathComponents[(marker + 1)...].joined(separator: "/")
    }

    private var worktreeMarker: Int? {
        let parts = directory.pathComponents
        guard let marker = parts.lastIndex(of: "worktrees"), marker >= 1, parts[marker - 1] == ".claude", marker + 1 < parts.count else { return nil }
        return marker
    }

    public func attention(desktop: DesktopSession?, seen: Date?) -> Attention? {
        if awaitsAnswer || desktop?.question != nil {
            return .waiting
        }
        guard let ended = desktop?.lastTurnEnded else { return nil }
        return ended > max(desktop?.lastFocused ?? .distantPast, seen ?? .distantPast) ? .unread : nil
    }
}

public enum Attention: Sendable, Equatable {
    case waiting, unread
}

public enum PullRequestState: String, Sendable, Comparable {
    case open = "OPEN", merged = "MERGED", closed = "CLOSED"

    private var rank: Int {
        switch self {
        case .closed: 0
        case .merged: 1
        case .open: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct PullRequestBadge: Sendable, Equatable {
    public let state: PullRequestState
    public let count: Int

    public init?(_ states: some Collection<PullRequestState>) {
        guard let state = states.max() else { return nil }
        self.state = state
        count = states.count
    }
}

public struct DesktopSession: Sendable, Equatable {
    public let title: String?
    public let isArchived: Bool
    public let pullRequests: [String: PullRequestState]
    public let question: String?
    public let lastTurnEnded: Date?
    public let lastFocused: Date?
    public let accountUUID: String?

    public init(
        title: String?, isArchived: Bool, pullRequests: [String: PullRequestState] = [:],
        question: String? = nil, lastTurnEnded: Date? = nil, lastFocused: Date? = nil, accountUUID: String? = nil
    ) {
        self.title = title
        self.isArchived = isArchived
        self.pullRequests = pullRequests
        self.question = question
        self.lastTurnEnded = lastTurnEnded
        self.lastFocused = lastFocused
        self.accountUUID = accountUUID
    }
}

public enum SessionOwners {
    public static func resolve(
        _ ids: [String], accounts: [ClaudeAccount], assigned: [String: String], desktop: [String: DesktopSession]
    ) -> [String: String] {
        guard let fallback = accounts.first?.id else { return [:] }
        let known = Set(accounts.map(\.id))
        let byUUID = Dictionary(accounts.compactMap { account in account.accountUUID().map { ($0, account.id) } }, uniquingKeysWith: { first, _ in first })
        let runs = accounts.map { ($0.id, $0.sessionRuns()) }
        var owners: [String: String] = [:]
        for id in ids {
            if let owner = assigned[id], known.contains(owner) {
                owners[id] = owner
            } else if let uuid = desktop[id]?.accountUUID, let owner = byUUID[uuid] {
                owners[id] = owner
            } else {
                let latest = runs.compactMap { account, runs in runs[id].map { (account, $0) } }.max { $0.1 < $1.1 }
                owners[id] = latest?.0 ?? fallback
            }
        }
        return owners
    }
}

public enum SessionLibrary {
    public static func projectDirectories(for accounts: [ClaudeAccount]) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var seen = Set<String>()
        return accounts.compactMap { account in
            let projects = (account.configDirectory ?? home.appending(path: ".claude")).appending(path: "projects")
            let resolved = projects.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: resolved.path), seen.insert(resolved.path).inserted else { return nil }
            return resolved
        }
    }

    public static func recent(in projectDirectories: [URL], limit: Int = 150) -> [PastSession] {
        let files = FileManager.default
        var candidates: [(URL, Date)] = []
        for projects in projectDirectories {
            for project in (try? files.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let entries = (try? files.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in entries where file.pathExtension == "jsonl" {
                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    candidates.append((file, date))
                }
            }
        }
        return candidates
            .sorted { $0.1 > $1.1 }
            .prefix(limit * 2)
            .lazy
            .compactMap { summary(of: $0.0, lastActivity: $0.1) }
            .prefix(limit)
            .map { $0 }
    }

    public static func summary(of file: URL, lastActivity: Date) -> PastSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 96_000)) ?? Data()
        var tail = Data()
        if size > 96_000 {
            try? handle.seek(toOffset: size - min(size - 96_000, 256_000))
            tail = (try? handle.read(upToCount: 256_000)) ?? Data()
        }

        var directory: String?
        var branch: String?
        var firstPrompt: String?
        var title: String?
        var lastMessage: JSONValue?
        for entry in lines(head) + lines(tail) {
            if entry["isSidechain"]?.bool == true { continue }
            switch entry["type"]?.string {
            case "custom-title":
                title = entry["customTitle"]?.string ?? title
            case "relocated":
                directory = entry["relocatedCwd"]?.string ?? directory
            case "user":
                directory = directory ?? entry["cwd"]?.string
                branch = entry["gitBranch"]?.string ?? branch
                if firstPrompt == nil, entry["isMeta"]?.bool != true {
                    firstPrompt = History.userText(entry["message"]?["content"])
                }
                lastMessage = entry
            case "assistant":
                directory = directory ?? entry["cwd"]?.string
                lastMessage = entry
            default:
                break
            }
        }
        guard let directory, let label = title ?? firstPrompt else { return nil }
        return PastSession(
            id: file.deletingPathExtension().lastPathComponent,
            file: file,
            directory: URL(filePath: directory),
            title: String(label.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces),
            lastActivity: lastActivity,
            branch: branch,
            awaitsAnswer: lastMessage.map(asksTheUser) ?? false
        )
    }

    private static func asksTheUser(_ entry: JSONValue) -> Bool {
        guard entry["type"]?.string == "assistant" else { return false }
        return (entry["message"]?["content"]?.array ?? []).contains {
            $0["type"]?.string == "tool_use" && $0["name"]?.string == "AskUserQuestion"
        }
    }

    public static func relevant(
        _ sessions: [PastSession], desktop: [String: DesktopSession],
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [PastSession] {
        let temporary = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        return sessions.filter { session in
            let path = session.directory.path + "/"
            return desktop[session.id]?.isArchived != true
                && !temporary.contains(where: path.hasPrefix)
                && exists(session.directory)
        }
    }

    public static func desktopSessions(in folder: URL? = nil) -> [String: DesktopSession] {
        let root = folder ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/claude-code-sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var sessions: [String: DesktopSession] = [:]
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let session = JSONValue(object)
            guard let id = session["cliSessionId"]?.string else { continue }
            let pullRequests = (session["prs"]?.array ?? []).compactMap { pullRequest -> (String, PullRequestState)? in
                guard let url = pullRequest["url"]?.string,
                      let state = pullRequest["state"]?.string.flatMap(PullRequestState.init) else { return nil }
                return (url, state)
            }
            sessions[id] = DesktopSession(
                title: session["title"]?.string,
                isArchived: session["isArchived"]?.bool ?? false,
                pullRequests: Dictionary(pullRequests, uniquingKeysWith: { $1 }),
                question: session["turnWrapUp"]?["needsUser"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                lastTurnEnded: date(session["lastTurnEdgeAt"]),
                lastFocused: date(session["lastFocusedAt"]),
                accountUUID: file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            )
        }
        return sessions
    }

    private static func date(_ milliseconds: JSONValue?) -> Date? {
        milliseconds?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    static func lines(_ data: Data) -> [JSONValue] {
        data.split(separator: 0x0A).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))).map(JSONValue.init)
        }
    }
}

public enum HistoryEntry: Sendable, Equatable {
    case user(String)
    case event(Incoming)
    case compacted
}

public enum History {
    public static func entries(in file: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return entries(from: SessionLibrary.lines(data))
    }

    static func entries(from lines: [JSONValue]) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        for line in lines where line["isSidechain"]?.bool != true {
            switch line["type"]?.string {
            case "user":
                guard line["isMeta"]?.bool != true else { continue }
                let result = Wire.parse(line)
                if result != .ignored {
                    entries.append(.event(result))
                } else if let text = userText(line["message"]?["content"]) {
                    entries.append(.user(text))
                }
            case "assistant":
                let event = Wire.parse(line)
                if event != .ignored {
                    entries.append(.event(event))
                }
            case "system" where line["subtype"]?.string == "compact_boundary":
                entries.append(.compacted)
            default:
                break
            }
        }
        return entries
    }

    static func userText(_ content: JSONValue?) -> String? {
        let pieces: [String]
        switch content {
        case .string(let text): pieces = [text]
        case .array(let blocks): pieces = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
        default: return nil
        }
        let visible = pieces
            .map { $0.replacing(/<system-reminder>[\s\S]*?<\/system-reminder>/, with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<command-") && !$0.hasPrefix("<local-command") && !$0.hasPrefix("Caveat:") }
        return visible.isEmpty ? nil : visible.joined(separator: "\n\n")
    }
}
