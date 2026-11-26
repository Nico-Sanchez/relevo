import Foundation

public struct NewSessionLink: Sendable, Equatable {
    public enum Problem: Error, Sendable, Equatable {
        case notNewSessionLink
        case missingAccount
        case unknownAccount(String)
        case missingFolder
        case folderNotFound(String)
    }

    public let accountID: String
    public let folder: String
    public let prompt: String
}

extension NewSessionLink {
    public init(_ url: URL) throws(Problem) {
        guard url.scheme?.lowercased() == "relevo-code", url.host() == "new", ["", "/"].contains(url.path()),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw .notNewSessionLink }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let accountID = value("account") else { throw .missingAccount }
        guard let folder = value("folder") else { throw .missingFolder }
        self.accountID = accountID
        self.folder = folder
        prompt = value("prompt") ?? ""
    }

    public func resolve(in accounts: [ClaudeAccount]) throws(Problem) -> (account: ClaudeAccount, folder: URL) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw .unknownAccount(accountID) }
        var isDirectory: ObjCBool = false
        guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw .folderNotFound(folder) }
        return (account, URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL)
    }
}
