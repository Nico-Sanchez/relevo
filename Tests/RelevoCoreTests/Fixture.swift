import CommonCrypto
import Foundation
import SQLite3
@testable import RelevoCore

let accountA = "aaaaaaaa-0000-0000-0000-000000000001"
let accountB = "bbbbbbbb-0000-0000-0000-000000000002"
let accountC = "cccccccc-0000-0000-0000-000000000003"
let orgA = "11111111-0000-0000-0000-00000000000a"
let orgB = "22222222-0000-0000-0000-00000000000b"
let orgC = "33333333-0000-0000-0000-00000000000c"

func location(_ account: String, _ org: String) -> Location {
    Location(account: account, org: org)!
}

struct FixtureError: Error {}

func sha256(_ data: Data) -> Data {
    var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
    digest.withUnsafeMutableBytes { digestBytes in
        data.withUnsafeBytes { dataBytes in
            _ = CC_SHA256(dataBytes.baseAddress, CC_LONG(data.count), digestBytes.baseAddress?.assumingMemoryBound(to: UInt8.self))
        }
    }
    return digest
}

final class Fixture {
    let root: URL
    let paths: DesktopPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "relevo-\(UUID().uuidString)")
        paths = DesktopPaths(
            data: root.appending(path: "data"),
            logs: root.appending(path: "logs"),
            storage: root.appending(path: "storage")
        )
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func store(claudeRunning: Bool = false) -> AccountStore {
        AccountStore(paths: paths, isClaudeRunning: { claudeRunning })
    }

    func signIn(_ account: String, session: String) throws {
        var config = (try? JSONFile.read(paths.config)) ?? ["locale": "es-419", "keep": 1]
        config["lastKnownAccountUuid"] = account
        config["oauth:tokenCache"] = "\(session)-tokens"
        config["bootSideSessions"] = ["accountUuid": account] as [String: Any]
        try JSONFile.write(config, to: paths.config)
        try writeCookies(session: session)
    }

    func writeCookies(session: String?, encryptedWith key: Data? = nil) throws {
        try? FileManager.default.removeItem(at: paths.cookies)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(paths.cookies.path, &database) == SQLITE_OK else { throw FixtureError() }
        var statements = "create table meta(key text, value text); insert into meta values('version', '24');"
        statements += "create table cookies(host_key text, name text, value text, encrypted_value blob);"
        statements += "insert into cookies values('.claude.ai', 'lastActiveOrg', 'org', x'');"
        if let session, let key {
            let plaintext = sha256(Data(".claude.ai".utf8)) + Data(session.utf8)
            let hex = try SafeStorage.encrypt(plaintext, key: key).map { String(format: "%02x", $0) }.joined()
            statements += "insert into cookies values('.claude.ai', 'sessionKey', '', x'\(hex)');"
        } else if let session {
            statements += "insert into cookies values('.claude.ai', 'sessionKey', '\(session)', x'');"
        }
        guard sqlite3_exec(database, statements, nil, nil, nil) == SQLITE_OK else { throw FixtureError() }
        FileManager.default.createFile(atPath: paths.data.appending(path: "Cookies-journal").path, contents: Data())
    }

    func cookieSession(in url: URL? = nil) -> String? {
        let url = url ?? paths.cookies
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "select value from cookies where name = 'sessionKey'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    func append(_ text: String, toLog name: String) throws {
        let url = paths.logs.appending(path: name)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + text).write(to: url, atomically: true, encoding: .utf8)
    }

    func logInitialization(_ account: String, _ org: String, in name: String = "main.log") throws {
        try append(
            "2026-10-28 12:00:00 [info] [LocalSessionManager] Initialization succeeded — accountId=\(account), orgId=\(org), existingSessions=1\n",
            toLog: name
        )
    }

    func age(log name: String, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -seconds)],
            ofItemAtPath: paths.logs.appending(path: name).path
        )
    }

    func addSession(
        _ id: String,
        at folder: String,
        title: String = "Sesión",
        lastActivity: Double = 1_792_000_000_000,
        archived: Bool = false
    ) throws {
        let directory = paths.sessions.appending(path: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session: [String: Any] = ["sessionId": id, "title": title, "lastActivityAt": lastActivity, "isArchived": archived]
        try JSONFile.write(session, to: directory.appending(path: "\(id).json"))
    }

    func sessionFiles() -> [String] {
        let base = paths.sessions.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: paths.sessions, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent.hasPrefix("local_") }
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: base, with: "") }
            .sorted()
    }

    func config() throws -> [String: Any] {
        try JSONFile.read(paths.config)
    }

    func permissions(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }
}
