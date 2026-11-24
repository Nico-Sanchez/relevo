import Foundation

public protocol PullRequestSource: Sendable {
    func viewer() throws -> String
    func pullRequest() throws -> PullRequest?
    func failedLog(of check: Check, in pullRequest: PullRequest) throws -> String?
}

public struct CommandError: Error, CustomStringConvertible {
    public let arguments: [String]
    public let status: Int32
    public let output: String

    public var description: String { "gh \(arguments.joined(separator: " ")) exited \(status): \(output)" }
}

public struct GitHubCLI: PullRequestSource {
    public let directory: URL
    public let environment: [String: String]?

    public init(directory: URL, environment: [String: String]? = nil) {
        self.directory = directory
        self.environment = environment
    }

    public func viewer() throws -> String {
        String(decoding: try gh(["api", "user", "--jq", ".login"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func pullRequest() throws -> PullRequest? {
        let data: Data
        do {
            data = try gh(["pr", "view", "--json", PullRequest.fields])
        } catch let error as CommandError where error.output.contains("no pull requests found") {
            return nil
        }
        var pullRequest = try PullRequest.decode(data)
        if let repository = pullRequest.repository {
            let inline = try gh([
                "api", "--hostname", repository.host, "--paginate",
                "repos/\(repository.owner)/\(repository.name)/pulls/\(pullRequest.number)/comments",
                "--jq", PullRequest.inlineCommentsFilter,
            ])
            pullRequest.feedback += try PullRequest.decodeInlineComments(inline)
        }
        return pullRequest
    }

    public func failedLog(of check: Check, in pullRequest: PullRequest) throws -> String? {
        guard let run = check.run, let repository = pullRequest.repository else { return nil }
        var arguments = ["run", "view", run.id, "--log-failed", "--repo", repository.slug]
        if let job = run.job {
            arguments += ["--job", job]
        }
        return LogExcerpt.make(from: String(decoding: try gh(arguments), as: UTF8.self))
    }

    private func gh(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["gh"] + arguments
        process.currentDirectoryURL = directory
        var environment = self.environment ?? ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        let errors = FileManager.default.temporaryDirectory.appending(path: "relevo-ci-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errors) }
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errors)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            throw CommandError(arguments: arguments, status: process.terminationStatus, output: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
