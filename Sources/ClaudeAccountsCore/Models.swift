import Foundation

public struct Location: Hashable, Sendable, CustomStringConvertible {
    public let account: String
    public let org: String

    public init?(account: String, org: String) {
        guard isIdentifier(account), isIdentifier(org) else { return nil }
        self.account = account
        self.org = org
    }

    public init?(path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(account: String(parts[0]), org: String(parts[1]))
    }

    public var description: String { "\(account)/\(org)" }
}

public struct Account: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let location: Location?
    public let orgName: String?
}

public struct Snapshot: Sendable {
    public let current: Account?
    public let others: [Account]

    public static let empty = Snapshot(current: nil, others: [])

    public var accounts: [Account] { (current.map { [$0] } ?? []) + others }
}

public struct SessionSummary: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let lastActivity: Date
    let file: URL
}

public struct SessionGroup: Hashable, Sendable, Identifiable {
    public let location: Location
    public let accountName: String?
    public let orgName: String?
    public let sessions: [SessionSummary]

    public var id: String { location.description }
}

public struct BringResult: Equatable, Sendable {
    public let moved: Int
    public let kept: Int
}

public struct UsageWindow: Hashable, Sendable, Identifiable {
    public let id: String
    public let utilization: Double
    public let resetsAt: Date?

    public init(id: String, utilization: Double, resetsAt: Date?) {
        self.id = id
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct Usage: Hashable, Sendable {
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(windows: [UsageWindow], fetchedAt: Date) {
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public func window(_ id: String) -> UsageWindow? {
        windows.first { $0.id == id }
    }
}

public enum AccountError: Error, Equatable {
    case claudeRunning
    case alreadyCurrent(String)
    case noSavedLogin(String)
    case notSignedInto(String)
    case invalidAccount(String)
    case unreadableConfig
}

public enum UsageError: Error, Equatable {
    case keychainDenied
    case noSession
    case http(Int)
    case unreadable
}

func isIdentifier(_ value: String) -> Bool {
    value.count == 36 && value.allSatisfy { "0123456789abcdef-".contains($0) }
}
