import Foundation

public struct DiffFile: Sendable, Equatable, Identifiable {
    public enum Change: String, Sendable {
        case added, modified, deleted, renamed
    }

    public let path: String
    public let oldPath: String?
    public let change: Change
    public let hunks: [DiffHunk]
    public let isBinary: Bool

    public var id: String { path }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("+") }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("-") }.count } }
}

public enum DiffScope: String, Sendable, CaseIterable, Identifiable {
    case uncommitted, branch

    public var id: String { rawValue }
}

public struct DiffResult: Sendable, Equatable {
    public let files: [DiffFile]
    public let base: String?
}

public enum GitDiff {
    public static func isRepository(_ directory: URL) -> Bool {
        var components = directory.standardizedFileURL.pathComponents
        while !components.isEmpty {
            let folder = URL(filePath: NSString.path(withComponents: components + [".git"]))
            if FileManager.default.fileExists(atPath: folder.path) {
                return true
            }
            components.removeLast()
        }
        return false
    }

    public static func load(in directory: URL, scope: DiffScope, environment: [String: String]) throws -> DiffResult {
        let git = Git(directory: directory, environment: environment)
        var base: String?
        let target: String
        switch scope {
        case .uncommitted:
            target = "HEAD"
        case .branch:
            let upstream = (try? git.run(["rev-parse", "--abbrev-ref", "origin/HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reference = [upstream, "origin/main", "origin/master", "main", "master"].compactMap { $0 }.first { git.succeeds(["rev-parse", "--verify", "--quiet", $0]) } ?? "HEAD"
            base = reference
            target = try git.run(["merge-base", "HEAD", reference]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var files = parse(try git.run(["diff", "--no-color", "--no-ext-diff", "--find-renames", target]))
        let untracked = try git.run(["ls-files", "--others", "--exclude-standard", "-z"])
            .split(separator: "\0").prefix(100).map(String.init)
        files += untracked.map { addedFile($0, in: directory) }
        return DiffResult(files: files.sorted { $0.path < $1.path }, base: base)
    }

    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var path: String?
        var oldPath: String?
        var change = DiffFile.Change.modified
        var hunks: [DiffHunk] = []
        var lines: [String] = []
        var start = (old: 0, new: 0)
        var binary = false
        var inHunk = false

        func closeHunk() {
            if inHunk {
                hunks.append(DiffHunk(oldStart: start.old, newStart: start.new, lines: lines))
            }
            lines = []
            inHunk = false
        }

        func closeFile() {
            closeHunk()
            if let path {
                files.append(DiffFile(path: path, oldPath: change == .renamed ? oldPath : nil, change: change, hunks: hunks, isBinary: binary))
            }
            path = nil
            oldPath = nil
            change = .modified
            hunks = []
            binary = false
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                if let match = line.firstMatch(of: /^diff --git a\/(.+) b\/(.+)$/) {
                    oldPath = String(match.1)
                    path = String(match.2)
                }
            } else if inHunk, let first = line.first, "+- \\".contains(first) {
                if first != "\\" {
                    lines.append(String(line))
                }
            } else if let match = line.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                closeHunk()
                start = (Int(match.1) ?? 0, Int(match.2) ?? 0)
                inHunk = true
            } else if line.hasPrefix("new file mode") {
                change = .added
            } else if line.hasPrefix("deleted file mode") {
                change = .deleted
            } else if line.hasPrefix("rename from ") {
                change = .renamed
                oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                path = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") {
                binary = true
            }
        }
        closeFile()
        return files
    }

    static func addedFile(_ path: String, in directory: URL) -> DiffFile {
        let url = directory.appending(path: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 200_000, let data = try? Data(contentsOf: url), !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return DiffFile(path: path, oldPath: nil, change: .added, hunks: [], isBinary: true)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" }
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return DiffFile(path: path, oldPath: nil, change: .added, hunks: lines.isEmpty ? [] : [DiffHunk(oldStart: 0, newStart: 1, lines: lines)], isBinary: false)
    }
}

struct Git {
    let directory: URL
    let environment: [String: String]

    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = directory
        process.environment = environment.isEmpty ? nil : environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(message: String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }

    func succeeds(_ arguments: [String]) -> Bool {
        (try? run(arguments)) != nil
    }
}

public struct GitError: Error, CustomStringConvertible {
    public let message: String

    public var description: String { message }
}
