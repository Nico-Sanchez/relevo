import Foundation
import SQLite3

enum JSONFile {
    static func read(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else { throw AccountError.unreadableConfig }
        return dictionary
    }

    static func readIfPresent(_ url: URL) -> [String: Any]? {
        try? read(url)
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        try writePrivately(data, to: url)
    }

    static func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

enum Folders {
    static func createPrivate(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func subfolders(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func copyOrRemove(_ source: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            try files.removeItem(at: destination)
        }
        if files.fileExists(atPath: source.path) {
            try files.copyItem(at: source, to: destination)
        }
    }
}

enum Cookies {
    static func hasClaudeSession(_ url: URL) -> Bool {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "select count(*) from cookies where name = 'sessionKey' and host_key like '%claude.ai'"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) > 0
    }

    static func sessionKey(in url: URL, key: Data) throws -> String {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw UsageError.noSession }
        let version = Int(text(database, "select value from meta where key = 'version'") ?? "") ?? 0

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = """
            select value, encrypted_value from cookies
            where name = 'sessionKey' and host_key like '%claude.ai'
            order by host_key = '.claude.ai' desc limit 1
            """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw UsageError.noSession }
        if let plain = sqlite3_column_text(statement, 0), plain.pointee != 0 {
            return String(cString: plain)
        }
        guard let bytes = sqlite3_column_blob(statement, 1) else { throw UsageError.noSession }
        let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        var decrypted = try SafeStorage.decrypt(encrypted, key: key)
        if version >= 24 {
            decrypted = decrypted.dropFirst(32)
        }
        guard let value = String(data: decrypted, encoding: .utf8), !value.isEmpty else { throw UsageError.unreadable }
        return value
    }

    private static func text(_ database: OpaquePointer?, _ query: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }
}
