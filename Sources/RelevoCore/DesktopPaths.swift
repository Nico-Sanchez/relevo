import Foundation

public struct DesktopPaths: Sendable {
    public var data: URL
    public var logs: URL
    public var storage: URL

    public init(data: URL, logs: URL, storage: URL) {
        self.data = data
        self.logs = logs
        self.storage = storage
    }

    public static var standard: DesktopPaths {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return DesktopPaths(
            data: library.appending(path: "Application Support/Claude"),
            logs: library.appending(path: "Logs/Claude"),
            storage: library.appending(path: "Application Support/Relevo")
        )
    }

    var sessions: URL { data.appending(path: "claude-code-sessions") }
    var config: URL { data.appending(path: "config.json") }
    var cookies: URL { data.appending(path: "Cookies") }
    var profiles: URL { storage.appending(path: "profiles") }
    var backup: URL { storage.appending(path: "backup") }
    var labels: URL { storage.appending(path: "labels.json") }

    func sessions(at location: Location) -> URL {
        sessions.appending(path: location.account).appending(path: location.org)
    }

    func profile(_ account: String) -> URL {
        profiles.appending(path: account)
    }
}
