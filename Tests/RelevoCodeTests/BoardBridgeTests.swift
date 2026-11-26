import Foundation
import Testing
@testable import RelevoCode
@testable import RelevoCodeApp

@Suite struct NewSessionLinkTests {
    func link(_ string: String) throws(NewSessionLink.Problem) -> NewSessionLink {
        try NewSessionLink(URL(string: string)!)
    }

    @Test func readsAccountFolderAndPercentEncodedPrompt() throws {
        let parsed = try link("relevo-code://new?account=%2FUsers%2Fana%2F.claude-work&folder=%2FUsers%2Fana%2Fcode%2Fsite&prompt=Fix%20%23123%3A%20a%26b%3Dc%2Bd%0Asecond%20line%20%C3%B1")
        #expect(parsed == NewSessionLink(accountID: "/Users/ana/.claude-work", folder: "/Users/ana/code/site", prompt: "Fix #123: a&b=c+d\nsecond line ñ"))
    }

    @Test func keepsAPlusSignLiteral() throws {
        #expect(try link("relevo-code://new?account=~/.claude&folder=/tmp&prompt=a+b").prompt == "a+b")
    }

    @Test func treatsAMissingOrEmptyPromptAsEmpty() throws {
        #expect(try link("relevo-code://new?account=~/.claude&folder=/tmp").prompt == "")
        #expect(try link("relevo-code://new/?account=~/.claude&folder=/tmp&prompt=").prompt == "")
    }

    @Test func refusesOtherLinks() {
        for string in ["claude://code/new?folder=/tmp", "relevo-code://open?account=~/.claude&folder=/tmp", "relevo-code://new/session?account=~/.claude&folder=/tmp"] {
            #expect(throws: NewSessionLink.Problem.notNewSessionLink) { try link(string) }
        }
    }

    @Test func needsAnAccountAndAFolder() {
        #expect(throws: NewSessionLink.Problem.missingAccount) { try link("relevo-code://new?folder=/tmp") }
        #expect(throws: NewSessionLink.Problem.missingAccount) { try link("relevo-code://new?account=&folder=/tmp") }
        #expect(throws: NewSessionLink.Problem.missingFolder) { try link("relevo-code://new?account=~/.claude&prompt=hi") }
    }

    @Test func resolvesTheAccountByIDAndAnExistingFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let work = ClaudeAccount(configDirectory: URL(filePath: "/Users/ana/.claude-work"))
        let accounts = [ClaudeAccount.standard, work]

        let standard = try NewSessionLink(accountID: "~/.claude", folder: folder.path, prompt: "").resolve(in: accounts)
        #expect(standard.account == .standard)
        #expect(standard.folder.path == folder.standardizedFileURL.path)
        #expect(try NewSessionLink(accountID: "/Users/ana/.claude-work", folder: folder.path + "/", prompt: "").resolve(in: accounts).account == work)
    }

    @Test func refusesAnUnknownAccountOrAFolderThatIsNotThere() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let accounts = [ClaudeAccount.standard]

        #expect(throws: NewSessionLink.Problem.unknownAccount("/Users/ana/.claude-other")) {
            try NewSessionLink(accountID: "/Users/ana/.claude-other", folder: "/tmp", prompt: "").resolve(in: accounts)
        }
        for folder in ["/nonexistent/\(UUID().uuidString)", file.path, "tmp", "~/"] {
            #expect(throws: NewSessionLink.Problem.folderNotFound(folder)) {
                try NewSessionLink(accountID: "~/.claude", folder: folder, prompt: "").resolve(in: accounts)
            }
        }
    }
}

@Suite struct AccountsFileTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var file: URL { directory.appending(path: "Relevo/code-accounts.json") }

    let windows = [
        UsageWindow(id: "seven_day_opus", utilization: 40.4, resetsAt: Date(timeIntervalSince1970: 1_796_000_000)),
        UsageWindow(id: "seven_day", utilization: 61.6, resetsAt: Date(timeIntervalSince1970: 1_795_986_000)),
        UsageWindow(id: "five_hour", utilization: 8.000000000000002, resetsAt: Date(timeIntervalSince1970: 1_795_497_000)),
    ]

    func snapshots(usageAt date: Date = Date(timeIntervalSince1970: 1_795_480_000)) -> [AccountSnapshot] {
        [
            AccountSnapshot(account: .standard, info: nil, usage: nil),
            AccountSnapshot(
                account: ClaudeAccount(configDirectory: URL(filePath: "/Users/ana/.claude-work")),
                info: AccountInfo(email: "ana@work.example", organization: "Work", subscription: "max"),
                usage: AccountUsage(windows, at: date)
            ),
        ]
    }

    func object(at file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    @Test func labelsTheWindowsTheWayTheBoardReadsThem() {
        #expect(AccountUsage(windows, at: .now).windows.map(\.label) == ["5-hour", "Weekly", "Weekly · Opus"])
        let others = [UsageWindow(id: "seven_day_overage_included", utilization: 1, resetsAt: nil), UsageWindow(id: "overage", utilization: 1, resetsAt: nil)]
        #expect(others.map(\.label) == ["Weekly · Overage included", "overage"])
    }

    @Test func writesTheDocumentedShape() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try AccountsFile.write(snapshots(), at: Date(timeIntervalSince1970: 1_795_480_060), to: file)

        let root = try object(at: file)
        #expect(Set(root.keys) == ["updatedAt", "accounts"])
        #expect(root["updatedAt"] as? String == "2026-11-24T00:27:40Z")
        let accounts = try #require(root["accounts"] as? [[String: Any]])
        #expect(accounts.count == 2)
        for account in accounts {
            #expect(Set(account.keys) == ["id", "configDir", "email", "organization", "subscription", "usage"])
        }

        #expect(accounts[0]["id"] as? String == "~/.claude")
        for key in ["configDir", "email", "organization", "subscription", "usage"] {
            #expect(accounts[0][key] is NSNull, "\(key) should be null")
        }

        let work = accounts[1]
        #expect(work["id"] as? String == "/Users/ana/.claude-work")
        #expect(work["configDir"] as? String == "/Users/ana/.claude-work")
        #expect(work["email"] as? String == "ana@work.example")
        #expect(work["organization"] as? String == "Work")
        #expect(work["subscription"] as? String == "max")
        let usage = try #require(work["usage"] as? [String: Any])
        #expect(Set(usage.keys) == ["updatedAt", "windows"])
        #expect(usage["updatedAt"] as? String == "2026-11-24T00:26:40Z")
        let windows = try #require(usage["windows"] as? [[String: Any]])
        #expect(windows.map { $0["label"] as? String } == ["5-hour", "Weekly", "Weekly · Opus"])
        #expect(windows.map { $0["percentUsed"] as? Int } == [8, 62, 40])
        #expect(windows[0]["resetsAt"] as? String == "2026-11-24T05:10:00Z")
        for window in windows {
            #expect(Set(window.keys) == ["label", "percentUsed", "resetsAt"])
        }
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(#"\/"#))
    }

    @Test func writesNullWhenAWindowHasNoReset() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AccountSnapshot(
            account: .standard, info: nil,
            usage: AccountUsage([UsageWindow(id: "five_hour", utilization: 3, resetsAt: nil)], at: .now)
        )
        try AccountsFile.write([account], at: .now, to: file)

        let accounts = try #require(try object(at: file)["accounts"] as? [[String: Any]])
        let usage = try #require(accounts.first?["usage"] as? [String: Any])
        let window = try #require((usage["windows"] as? [[String: Any]])?.first)
        #expect(window["resetsAt"] is NSNull)
    }

    @Test func replacesTheFileAtomically() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try AccountsFile.write(snapshots(), at: .now, to: file)
        let first = try Data(contentsOf: file)
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }

        try AccountsFile.write(Array(snapshots().prefix(1)), at: .now, to: file)

        #expect(try reader.readToEnd() == first)
        #expect(try (object(at: file)["accounts"] as? [Any])?.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["code-accounts.json"])
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func readsBackTheLastUsageOfEachAccount() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = snapshots()
        try AccountsFile.write(written, at: .now, to: file)

        let usage = AccountsFile.usage(at: file)
        #expect(usage.keys.sorted() == ["/Users/ana/.claude-work"])
        #expect(usage["/Users/ana/.claude-work"] == written[1].usage)
    }

    @Test func readsNothingFromAMissingOrBrokenFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AccountsFile.usage(at: file).isEmpty)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"accounts\": [".utf8).write(to: file)
        #expect(AccountsFile.usage(at: file).isEmpty)
    }
}

@MainActor
@Suite struct SessionUsageTests {
    @Test func reportsEveryRateLimitEvent() {
        let session = Session(configuration: SessionConfiguration(directory: URL(filePath: "/tmp/project")), accountName: "Ana")
        var reported: [[UsageWindow]] = []
        session.onUsage = { reported.append($0) }

        session.apply(event(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.12,"resetsAt":1795497000}}}}"#))
        session.apply(event(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.13,"resetsAt":1795497000}}}}"#))

        #expect(reported.map { $0.map(\.utilization) } == [[12], [13]])
    }
}

@MainActor
@Suite(.serialized) struct OpenLinkTests {
    func loadedModel() -> AppModel {
        let model = AppModel()
        model.executable = URL(filePath: "/usr/bin/false")
        model.isLoaded = true
        return model
    }

    @Test func opensASessionThatRunsNothingUntilTheFirstMessage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = loadedModel()
        let remembered = model.lastPermissionMode
        model.lastPermissionMode = "bypassPermissions"
        defer { model.lastPermissionMode = remembered }

        model.openLink(URL(string: "relevo-code://new?account=~/.claude&folder=\(folder.path)&prompt=Fix%20it")!)

        let session = try #require(model.sessions.first)
        #expect(model.sessions.count == 1)
        #expect(session.status == .dormant)
        #expect(session.sessionID == nil)
        #expect(session.permissionMode == "default")
        #expect(session.configuration.configDirectory == nil)
        #expect(session.workingDirectory.path == folder.standardizedFileURL.path)
        #expect(model.drafts[session.id] == "Fix it")
        #expect(model.linkProblem == nil)
        model.close(session)
    }

    @Test func startsNothingForAnUnknownAccount() {
        let model = loadedModel()

        model.openLink(URL(string: "relevo-code://new?account=%2Fnowhere&folder=%2Ftmp&prompt=x")!)

        #expect(model.sessions.isEmpty)
        #expect(model.linkProblem != nil)
    }

    @Test func waitsForTheAccountsBeforeOpeningALink() {
        let model = AppModel()

        model.openLink(URL(string: "relevo-code://new?account=%2Fnowhere&folder=%2Ftmp")!)

        #expect(model.sessions.isEmpty)
        #expect(model.linkProblem == nil)
    }
}
