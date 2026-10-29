import AppKit
import Foundation

public struct AccountStore: Sendable {
    public static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    static let authKeys: Set<String> = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid", "bootSideSessions"]
    static let cookieFiles = ["Cookies", "Cookies-journal"]
    static let initializationMarker = "[LocalSessionManager] Initialization succeeded — accountId="

    public let paths: DesktopPaths
    private let isClaudeRunning: @Sendable () -> Bool

    public init(
        paths: DesktopPaths = .standard,
        isClaudeRunning: @escaping @Sendable () -> Bool = { AccountStore.claudeIsRunning() }
    ) {
        self.paths = paths
        self.isClaudeRunning = isClaudeRunning
    }

    public static func claudeIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleIdentifier).isEmpty
    }

    public func snapshot() -> Snapshot {
        resolvePendingName()
        let book = labelBook()
        let current = currentAccount()
        let location = activeLocation().flatMap { $0.account == current ? $0 : nil }
        let others = savedAccounts()
            .filter { $0 != current }
            .map { account(for: $0, location: savedLocation(of: $0), book: book) }
            .sorted { ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending }
        return Snapshot(current: current.map { account(for: $0, location: location, book: book) }, others: others)
    }

    public func currentAccount() -> String? {
        guard let account = JSONFile.readIfPresent(paths.config)?["lastKnownAccountUuid"] as? String,
              isIdentifier(account) else { return nil }
        return account
    }

    public func activeLocation() -> Location? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.logs, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let logs = entries
            .filter { $0.lastPathComponent.hasPrefix("main") && $0.pathExtension == "log" }
            .sorted { modificationDate($0) > modificationDate($1) }
        for log in logs {
            guard let data = try? Data(contentsOf: log) else { continue }
            if let location = Self.lastInitialization(in: String(decoding: data, as: UTF8.self)) {
                return location
            }
        }
        return nil
    }

    public func sessionGroups(excluding target: Location?) -> [SessionGroup] {
        let book = labelBook()
        var groups: [SessionGroup] = []
        for accountFolder in Folders.subfolders(of: paths.sessions) {
            for orgFolder in Folders.subfolders(of: accountFolder) {
                guard let location = Location(account: accountFolder.lastPathComponent, org: orgFolder.lastPathComponent),
                      location != target else { continue }
                let sessions = openSessions(at: location)
                if !sessions.isEmpty {
                    groups.append(SessionGroup(
                        location: location,
                        accountName: book.accounts[location.account],
                        orgName: book.orgs[location.org],
                        sessions: sessions
                    ))
                }
            }
        }
        return groups.sorted { ($0.sessions.first?.lastActivity ?? .distantPast) > ($1.sessions.first?.lastActivity ?? .distantPast) }
    }

    public func bring(_ sessions: [SessionSummary], to target: Location) throws -> BringResult {
        guard !isClaudeRunning() else { throw AccountError.claudeRunning }
        guard currentAccount() == target.account else { throw AccountError.notSignedInto(target.account) }
        let files = FileManager.default
        let destination = paths.sessions(at: target)
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved = 0
        var kept = 0
        for session in sessions {
            let source = session.file.standardizedFileURL
            guard source.path.hasPrefix(paths.sessions.standardizedFileURL.path + "/"),
                  source.deletingLastPathComponent() != destination.standardizedFileURL,
                  files.fileExists(atPath: source.path) else { continue }
            let newFile = destination.appending(path: source.lastPathComponent)
            if files.fileExists(atPath: newFile.path) {
                kept += 1
                continue
            }
            try files.moveItem(at: source, to: newFile)
            moved += 1
        }
        return BringResult(moved: moved, kept: kept)
    }

    public func switchTo(_ account: String) throws {
        guard isIdentifier(account) else { throw AccountError.invalidAccount(account) }
        try requireClosedAndReadableConfig()
        resolvePendingName()
        guard account != currentAccount() else { throw AccountError.alreadyCurrent(account) }
        let profile = paths.profile(account)
        guard let auth = JSONFile.readIfPresent(profile.appending(path: "profile.json"))?["auth"] as? [String: Any] else {
            throw AccountError.noSavedLogin(account)
        }
        try backUpLogin()
        try saveCurrentLogin()
        for file in Self.cookieFiles {
            try Folders.copyOrRemove(profile.appending(path: file), to: paths.data.appending(path: file))
        }
        try replaceAuth(with: auth)
    }

    public func switchToNewAccount(named name: String) throws {
        try requireClosedAndReadableConfig()
        resolvePendingName()
        try backUpLogin()
        try saveCurrentLogin()
        for file in Self.cookieFiles {
            let url = paths.data.appending(path: file)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try replaceAuth(with: [:])
        var book = labelBook()
        book.pending = trimmed(name)
        try save(book)
    }

    public func rename(_ account: String, to name: String) throws {
        var book = labelBook()
        book.accounts[account] = trimmed(name)
        try save(book)
    }

    public func name(of account: String) -> String? {
        labelBook().accounts[account]
    }

    public func sessionKey(for account: String, decryptingWith key: Data) throws -> String {
        guard account == currentAccount() else {
            return try Cookies.sessionKey(in: paths.profile(account).appending(path: "Cookies"), key: key)
        }
        let copy = FileManager.default.temporaryDirectory.appending(path: "relevo-\(UUID().uuidString)")
        try Folders.createPrivate(copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        for file in Self.cookieFiles {
            try Folders.copyOrRemove(paths.data.appending(path: file), to: copy.appending(path: file))
        }
        return try Cookies.sessionKey(in: copy.appending(path: "Cookies"), key: key)
    }

    static func lastInitialization(in text: String) -> Location? {
        var end = text.endIndex
        while let marker = text.range(of: initializationMarker, options: .backwards, range: text.startIndex..<end) {
            let rest = text[marker.upperBound...].prefix(80)
            let tail = rest.dropFirst(36)
            if tail.hasPrefix(", orgId="),
               let location = Location(account: String(rest.prefix(36)), org: String(tail.dropFirst(8).prefix(36))) {
                return location
            }
            end = marker.lowerBound
        }
        return nil
    }

    func openSessions(at location: Location) -> [SessionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: paths.sessions(at: location), includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            .compactMap { summary(of: $0) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    func summary(of file: URL) -> SessionSummary? {
        guard let session = JSONFile.readIfPresent(file), (session["isArchived"] as? Bool) != true else { return nil }
        let title = (session["title"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let milliseconds = (session["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0
        return SessionSummary(
            id: file.deletingPathExtension().lastPathComponent,
            title: title,
            lastActivity: Date(timeIntervalSince1970: milliseconds / 1000),
            file: file
        )
    }

    func requireClosedAndReadableConfig() throws {
        guard !isClaudeRunning() else { throw AccountError.claudeRunning }
        guard (try? JSONFile.read(paths.config)) != nil else { throw AccountError.unreadableConfig }
    }

    func backUpLogin() throws {
        try Folders.createPrivate(paths.storage)
        try Folders.createPrivate(paths.backup)
        for file in Self.cookieFiles + ["config.json"] {
            try Folders.copyOrRemove(paths.data.appending(path: file), to: paths.backup.appending(path: file))
        }
    }

    func saveCurrentLogin() throws {
        guard let account = currentAccount(), Cookies.hasClaudeSession(paths.cookies) else { return }
        let profile = paths.profile(account)
        try Folders.createPrivate(paths.storage)
        try Folders.createPrivate(paths.profiles)
        try Folders.createPrivate(profile)
        for file in Self.cookieFiles {
            try Folders.copyOrRemove(paths.data.appending(path: file), to: profile.appending(path: file))
        }
        let config = try JSONFile.read(paths.config)
        var saved: [String: Any] = ["auth": config.filter { Self.authKeys.contains($0.key) }]
        let location = activeLocation().flatMap { $0.account == account ? $0 : nil } ?? savedLocation(of: account)
        if let location {
            saved["location"] = location.description
        }
        try JSONFile.write(saved, to: profile.appending(path: "profile.json"))
    }

    func replaceAuth(with auth: [String: Any]) throws {
        var config = try JSONFile.read(paths.config)
        for key in Self.authKeys {
            config.removeValue(forKey: key)
        }
        config.merge(auth) { _, saved in saved }
        try JSONFile.write(config, to: paths.config)
    }

    func savedAccounts() -> [String] {
        Folders.subfolders(of: paths.profiles)
            .map(\.lastPathComponent)
            .filter { isIdentifier($0) && FileManager.default.fileExists(atPath: paths.profile($0).appending(path: "profile.json").path) }
    }

    func savedLocation(of account: String) -> Location? {
        let profile = JSONFile.readIfPresent(paths.profile(account).appending(path: "profile.json"))
        return (profile?["location"] as? String).flatMap(Location.init(path:))
    }

    func labelBook() -> LabelBook {
        guard let data = try? Data(contentsOf: paths.labels) else { return LabelBook() }
        return (try? JSONDecoder().decode(LabelBook.self, from: data)) ?? LabelBook()
    }

    func save(_ book: LabelBook) throws {
        try Folders.createPrivate(paths.storage)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try JSONFile.writePrivately(encoder.encode(book), to: paths.labels)
    }

    func resolvePendingName() {
        var book = labelBook()
        guard let pending = book.pending, let account = currentAccount() else { return }
        if book.accounts[account] == nil {
            book.accounts[account] = pending
        }
        book.pending = nil
        try? save(book)
    }

    func account(for id: String, location: Location?, book: LabelBook) -> Account {
        Account(id: id, name: book.accounts[id], location: location, orgName: location.flatMap { book.orgs[$0.org] })
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct LabelBook: Codable {
    var accounts: [String: String] = [:]
    var orgs: [String: String] = [:]
    var pending: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([String: String].self, forKey: .accounts) ?? [:]
        orgs = try container.decodeIfPresent([String: String].self, forKey: .orgs) ?? [:]
        pending = try container.decodeIfPresent(String.self, forKey: .pending)
    }
}
