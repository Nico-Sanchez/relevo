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
    public let name: String
    public let location: Location?
    public let orgName: String?
}

public struct Snapshot: Sendable {
    public let current: Account?
    public let others: [Account]

    public static let empty = Snapshot(current: nil, others: [])
}

public struct SessionSummary: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let lastActivity: Date
    let file: URL
}

public struct SessionGroup: Hashable, Sendable, Identifiable {
    public let location: Location
    public let name: String
    public let sessions: [SessionSummary]

    public var id: String { location.description }
}

public struct BringResult: Equatable, Sendable {
    public let moved: Int
    public let kept: Int
}

public enum AccountError: LocalizedError, Equatable {
    case claudeRunning
    case alreadyCurrent(String)
    case noSavedLogin(String)
    case notSignedInto(String)
    case invalidAccount(String)
    case unreadableConfig

    public var errorDescription: String? {
        switch self {
        case .claudeRunning:
            "Claude sigue abierto. No cambié nada."
        case .alreadyCurrent(let name):
            "Ya estás en \(name)."
        case .noSavedLogin(let name):
            "No tengo guardado el login de \(name)."
        case .notSignedInto(let name):
            "Claude no está en \(name). No moví ninguna sesión."
        case .invalidAccount(let account):
            "Cuenta inválida: \(account)."
        case .unreadableConfig:
            "No pude leer la configuración de Claude. No cambié nada."
        }
    }
}

func isIdentifier(_ value: String) -> Bool {
    value.count == 36 && value.allSatisfy { "0123456789abcdef-".contains($0) }
}
