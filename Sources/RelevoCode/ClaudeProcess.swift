import Foundation

public struct SessionConfiguration: Sendable, Equatable {
    public var directory: URL
    public var configDirectory: URL?
    public var resume: String?
    public var fork: Bool
    public var model: String?
    public var permissionMode: String
    public var worktree: String?
    public var effort: String?

    public init(
        directory: URL, configDirectory: URL? = nil, resume: String? = nil, fork: Bool = false,
        model: String? = nil, permissionMode: String = "default", worktree: String? = nil, effort: String? = nil
    ) {
        self.directory = directory
        self.configDirectory = configDirectory
        self.resume = resume
        self.fork = fork
        self.model = model
        self.permissionMode = permissionMode
        self.worktree = worktree
        self.effort = effort
    }

    public var arguments: [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", permissionMode,
        ]
        if permissionMode == "bypassPermissions" {
            arguments.append("--allow-dangerously-skip-permissions")
        }
        if let model {
            arguments += ["--model", model]
        }
        if let effort {
            arguments += ["--effort", effort]
        }
        if let resume {
            arguments += ["--resume", resume]
            if fork {
                arguments.append("--fork-session")
            }
        } else if let worktree {
            arguments += ["--worktree", worktree]
        }
        return arguments
    }

    public func environment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["CLAUDE_CONFIG_DIR"] = configDirectory?.path
        return environment
    }
}

public final class ClaudeProcess: @unchecked Sendable {
    public let events: AsyncStream<Incoming>
    private let continuation: AsyncStream<Incoming>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var errorTail = ""

    public init(configuration: SessionConfiguration, environment: [String: String], executable: URL) {
        (events, continuation) = AsyncStream.makeStream(of: Incoming.self)
        process.executableURL = executable
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.directory
        process.environment = configuration.environment(base: environment)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    public func start() throws {
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            self?.lock.withLock {
                guard let self else { return }
                self.errorTail = String((self.errorTail + chunk).suffix(4000))
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.errors.fileHandleForReading.readabilityHandler = nil
            let message = self.lock.withLock { self.errorTail }.trimmingCharacters(in: .whitespacesAndNewlines)
            self.continuation.yield(.exited(status: process.terminationStatus, message: message))
            self.continuation.finish()
        }
        try process.run()
        let reading = output.fileHandleForReading
        let continuation = continuation
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = reading.availableData
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let event = Wire.parse(Substring(decoding: line, as: UTF8.self))
                    if event != .ignored {
                        continuation.yield(event)
                    }
                }
            }
        }
    }

    public func send(_ message: [String: Any]) {
        guard process.isRunning,
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
    }

    public func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }
}

public enum ShellEnvironment {
    public static func load() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__RELEVO_ENVIRONMENT__"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-ilc", "printf '\(marker)'; env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        var environment = ProcessInfo.processInfo.environment
        guard (try? process.run()) != nil else { return environment }
        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning {
                process.terminate()
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: marker) else { return environment }
        for entry in text[range.upperBound...].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }

    public static func claudeExecutable(in environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" } + ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }
}
