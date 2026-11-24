import Foundation

public struct ClaudeAccount: Sendable, Equatable, Identifiable, Hashable {
    public let configDirectory: URL?

    public init(configDirectory: URL?) {
        self.configDirectory = configDirectory
    }

    public static let standard = ClaudeAccount(configDirectory: nil)

    public var id: String { configDirectory?.path ?? "~/.claude" }

    public var folderName: String {
        configDirectory.map { $0.abbreviatingHome } ?? "~/.claude"
    }

    public func status(executable: URL, environment: [String: String]) async -> AccountInfo? {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["auth", "status", "--json"]
            var environment = environment
            environment["CLAUDE_CONFIG_DIR"] = configDirectory?.path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            let status = JSONValue(object)
            guard status["loggedIn"]?.bool == true else { return nil }
            return AccountInfo(
                email: status["email"]?.string,
                organization: status["orgName"]?.string,
                subscription: status["subscriptionType"]?.string
            )
        }.value
    }
}

extension URL {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
