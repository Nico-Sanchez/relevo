import Foundation

public struct AccountUsage: Sendable, Equatable, Codable {
    public struct Window: Sendable, Equatable, Codable {
        public let label: String
        public let percentUsed: Int
        public let resetsAt: Date?

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(label, forKey: .label)
            try container.encode(percentUsed, forKey: .percentUsed)
            try container.encode(resetsAt, forKey: .resetsAt)
        }
    }

    public let updatedAt: Date
    public let windows: [Window]

    public init(_ windows: [UsageWindow], at date: Date) {
        updatedAt = date
        self.windows = windows.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }.map {
            Window(label: $0.label, percentUsed: Int($0.utilization.rounded()), resetsAt: $0.resetsAt)
        }
    }
}

extension UsageWindow {
    public var label: String {
        switch id {
        case "five_hour":
            return "5-hour"
        case "seven_day":
            return "Weekly"
        case let id where id.hasPrefix("seven_day_"):
            let name = id.dropFirst("seven_day_".count).replacing("_", with: " ")
            return "Weekly · " + name.prefix(1).uppercased() + name.dropFirst()
        default:
            return id
        }
    }

    fileprivate var rank: Int {
        id == "five_hour" ? 0 : id == "seven_day" ? 1 : id.hasPrefix("seven_day_") ? 2 : 3
    }
}

public struct AccountSnapshot: Sendable, Equatable, Codable {
    public let id: String
    public let configDir: String?
    public let email: String?
    public let organization: String?
    public let subscription: String?
    public let usage: AccountUsage?

    public init(account: ClaudeAccount, info: AccountInfo?, usage: AccountUsage?) {
        id = account.id
        configDir = account.configDirectory?.path
        email = info?.email
        organization = info?.organization
        subscription = info?.subscription
        self.usage = usage
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(configDir, forKey: .configDir)
        try container.encode(email, forKey: .email)
        try container.encode(organization, forKey: .organization)
        try container.encode(subscription, forKey: .subscription)
        try container.encode(usage, forKey: .usage)
    }
}

public enum AccountsFile {
    struct Contents: Codable {
        let updatedAt: Date
        let accounts: [AccountSnapshot]
    }

    public static var location: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Relevo/code-accounts.json")
    }

    public static func usage(at file: URL) -> [String: AccountUsage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file), let contents = try? decoder.decode(Contents.self, from: data) else { return [:] }
        return contents.accounts.reduce(into: [:]) { usage, account in
            usage[account.id] = account.usage
        }
    }

    public static func write(_ accounts: [AccountSnapshot], at date: Date, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Contents(updatedAt: date, accounts: accounts))
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
    }
}
