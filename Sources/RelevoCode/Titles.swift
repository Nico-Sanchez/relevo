import Foundation

public enum SessionTitle {
    public static let limit = 60

    public static func fallback(from text: String) -> String {
        let line = text.replacing(/https?:\/\/\S+/, with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        guard line.count > limit else { return line }
        let end = line.prefix(limit + 1).lastIndex(of: " ") ?? line.index(line.startIndex, offsetBy: limit)
        return String(line[..<end]) + "…"
    }

    public static func request(for text: String) -> String {
        """
        Write a title for a coding session that starts with the request below. Use 3 to 6 words, in the same \
        language as the request, sentence case, no quotes and no final period. Reply with the title only.

        Request:
        \(text.prefix(2000))
        """
    }

    public static func clean(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let title = line?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*#. ")),
              !title.isEmpty, title.count <= 80 else { return nil }
        return title
    }

    public static func arguments(for text: String) -> [String] {
        [
            "-p", "--no-session-persistence", "--model", "haiku", "--tools", "", "--setting-sources", "project",
            "--output-format", "text", request(for: text),
        ]
    }

    public static func generate(
        for text: String, configDirectory: URL?, environment: [String: String], executable: URL, folder: URL
    ) async -> String? {
        await Task.detached {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments(for: text)
            var environment = environment
            environment["CLAUDE_CONFIG_DIR"] = configDirectory?.path
            process.environment = environment
            process.currentDirectoryURL = folder
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let watchdog = Watchdog(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { watchdog.stop() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return clean(String(decoding: data, as: UTF8.self))
        }.value
    }
}

private final class Watchdog: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }
}
