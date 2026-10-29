import Foundation
import Testing
@testable import ClaudeAccountsCore

@Suite struct ActiveLocationTests {
    @Test func readsTheLastInitializationAcrossRotatedLogs() throws {
        let fixture = try Fixture()
        try fixture.logInitialization(accountA, orgA, in: "main1.log")
        try fixture.logInitialization(accountC, orgC, in: "main1.log")
        try fixture.append("2026-10-28 [info] nothing relevant\n", toLog: "main.log")
        try fixture.age(log: "main1.log", by: 3600)

        #expect(fixture.store().activeLocation() == location(accountC, orgC))

        try fixture.logInitialization(accountB, orgB)
        #expect(fixture.store().activeLocation() == location(accountB, orgB))
    }

    @Test func skipsMalformedInitializationLines() throws {
        let fixture = try Fixture()
        try fixture.logInitialization(accountA, orgA)
        try fixture.append(
            "[LocalSessionManager] Initialization succeeded — accountId=not-an-id, orgId=\(orgB)\n",
            toLog: "main.log"
        )

        #expect(fixture.store().activeLocation() == location(accountA, orgA))
    }
}

@Suite struct SwitchTests {
    @Test func addingAnAccountSavesTheCurrentLoginAndSignsOut() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        try fixture.logInitialization(accountA, orgA)
        let store = fixture.store()

        try store.switchToNewAccount(named: "  second@example.com ")

        let config = try fixture.config()
        #expect(config["lastKnownAccountUuid"] == nil)
        #expect(config["oauth:tokenCache"] == nil)
        #expect(config["bootSideSessions"] == nil)
        #expect(config["keep"] as? Int == 1)
        #expect(config["locale"] as? String == "es-419")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.cookies.path))

        let profile = fixture.paths.profile(accountA)
        #expect(fixture.cookieSession(in: profile.appending(path: "Cookies")) == "A")
        let saved = try JSONFile.read(profile.appending(path: "profile.json"))
        #expect((saved["auth"] as? [String: Any])?["oauth:tokenCache"] as? String == "A-tokens")
        #expect(saved["location"] as? String == location(accountA, orgA).description)

        let snapshot = store.snapshot()
        #expect(snapshot.current == nil)
        #expect(snapshot.others.map(\.id) == [accountA])
        #expect(snapshot.others.first?.location == location(accountA, orgA))
        #expect(store.labelBook().pending == "second@example.com")
    }

    @Test func thePendingNameGoesToTheAccountSignedInNext() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        let store = fixture.store()
        try store.switchToNewAccount(named: "second@example.com")
        try fixture.signIn(accountC, session: "C")
        try fixture.logInitialization(accountC, orgC)

        let snapshot = store.snapshot()

        #expect(snapshot.current?.id == accountC)
        #expect(snapshot.current?.name == "second@example.com")
        #expect(snapshot.current?.location == location(accountC, orgC))
        #expect(store.labelBook().pending == nil)
        #expect(store.labelBook().accounts[accountC] == "second@example.com")
    }

    @Test func thePendingNameIsDroppedWhenAKnownAccountSignsIn() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        let store = fixture.store()
        try store.rename(accountA, to: "Trabajo")
        try store.switchToNewAccount(named: "otra")
        try fixture.signIn(accountA, session: "A2")

        #expect(store.snapshot().current?.name == "Trabajo")
        #expect(store.labelBook().pending == nil)
    }

    @Test func switchingRestoresTheSavedLoginAndKeepsTheRestOfTheConfig() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        try fixture.logInitialization(accountA, orgA)
        let store = fixture.store()
        try store.switchToNewAccount(named: "C")
        try fixture.signIn(accountC, session: "C")
        try fixture.logInitialization(accountC, orgC)

        try store.switchTo(accountA)

        var config = try fixture.config()
        #expect(config["lastKnownAccountUuid"] as? String == accountA)
        #expect(config["oauth:tokenCache"] as? String == "A-tokens")
        #expect((config["bootSideSessions"] as? [String: Any])?["accountUuid"] as? String == accountA)
        #expect(config["keep"] as? Int == 1)
        #expect(fixture.cookieSession() == "A")
        let savedC = try JSONFile.read(fixture.paths.profile(accountC).appending(path: "profile.json"))
        #expect(savedC["location"] as? String == location(accountC, orgC).description)
        #expect(fixture.cookieSession(in: fixture.paths.profile(accountC).appending(path: "Cookies")) == "C")

        try fixture.logInitialization(accountA, orgA)
        try store.switchTo(accountC)

        config = try fixture.config()
        #expect(config["lastKnownAccountUuid"] as? String == accountC)
        #expect(config["oauth:tokenCache"] as? String == "C-tokens")
        #expect(fixture.cookieSession() == "C")
    }

    @Test func aSignedOutAccountDoesNotOverwriteItsSavedLogin() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        let store = fixture.store()
        try store.switchToNewAccount(named: "C")
        try fixture.signIn(accountC, session: "C")
        try store.switchTo(accountA)
        try store.switchTo(accountC)
        try fixture.writeCookies(session: nil)

        try store.switchTo(accountA)

        #expect(fixture.cookieSession() == "A")
        #expect(fixture.cookieSession(in: fixture.paths.profile(accountC).appending(path: "Cookies")) == "C")
    }

    @Test func switchingRefusesWhenItCannotRunSafely() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        let store = fixture.store()

        #expect(throws: AccountError.claudeRunning) {
            try fixture.store(claudeRunning: true).switchToNewAccount(named: "x")
        }
        #expect(throws: AccountError.alreadyCurrent("Cuenta aaaaaaaa")) { try store.switchTo(accountA) }
        #expect(throws: AccountError.noSavedLogin("Cuenta cccccccc")) { try store.switchTo(accountC) }
        #expect(throws: AccountError.invalidAccount("../x")) { try store.switchTo("../x") }
        #expect(fixture.cookieSession() == "A")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.storage.path))
    }

    @Test func anUnreadableConfigStopsTheSwitchBeforeTouchingAnything() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        try "{ not json".write(to: fixture.paths.config, atomically: true, encoding: .utf8)

        #expect(throws: AccountError.unreadableConfig) { try fixture.store().switchToNewAccount(named: "x") }
        #expect(fixture.cookieSession() == "A")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.storage.path))
    }

    @Test func theBackupHoldsTheLoginFromBeforeTheLastSwitch() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")

        try fixture.store().switchToNewAccount(named: "x")

        #expect(fixture.cookieSession(in: fixture.paths.backup.appending(path: "Cookies")) == "A")
        let backup = try JSONFile.read(fixture.paths.backup.appending(path: "config.json"))
        #expect(backup["lastKnownAccountUuid"] as? String == accountA)
    }

    @Test func savedLoginsAreOnlyReadableByTheUser() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")

        try fixture.store().switchToNewAccount(named: "x")

        let profile = fixture.paths.profile(accountA)
        #expect(try fixture.permissions(of: fixture.paths.storage) == 0o700)
        #expect(try fixture.permissions(of: fixture.paths.profiles) == 0o700)
        #expect(try fixture.permissions(of: profile) == 0o700)
        #expect(try fixture.permissions(of: profile.appending(path: "profile.json")) == 0o600)
        #expect(try fixture.permissions(of: fixture.paths.labels) == 0o600)
    }
}

@Suite struct SessionTests {
    @Test func groupsListOpenSessionsOutsideTheTargetMostRecentFirst() throws {
        let fixture = try Fixture()
        try fixture.addSession("local_a1", at: "\(accountA)/\(orgA)")
        try fixture.addSession("local_b1", at: "\(accountB)/\(orgB)", lastActivity: 1_791_000_000_000)
        try fixture.addSession("local_b2", at: "\(accountB)/\(orgB)", title: "Con\ttab\ny salto", lastActivity: 1_792_100_000_000)
        try fixture.addSession("local_b3", at: "\(accountB)/\(orgB)", lastActivity: 1_793_000_000_000, archived: true)
        try fixture.addSession("local_c1", at: "\(accountA)/\(orgC)", lastActivity: 1_792_500_000_000)
        try FileManager.default.createDirectory(
            at: fixture.paths.sessions.appending(path: "\(accountB)/\(orgA)"), withIntermediateDirectories: true
        )
        try fixture.addSession("local_w1", at: "weird/folder")

        let groups = fixture.store().sessionGroups(excluding: location(accountA, orgA))

        #expect(groups.map(\.location) == [location(accountA, orgC), location(accountB, orgB)])
        #expect(groups[1].sessions.map(\.id) == ["local_b2", "local_b1"])
        #expect(groups[1].sessions[0].title == "Con tab y salto")
        #expect(groups[1].name == "Cuenta bbbbbbbb · org 22222222")
    }

    @Test func bringingMovesTheChosenSessionsAndKeepsDuplicates() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        try fixture.addSession("local_dup", at: "\(accountA)/\(orgA)")
        try fixture.addSession("local_b1", at: "\(accountB)/\(orgB)")
        try fixture.addSession("local_dup", at: "\(accountB)/\(orgB)")
        let store = fixture.store()
        let sessions = store.sessionGroups(excluding: location(accountA, orgA)).flatMap(\.sessions)

        let result = try store.bring(sessions, to: location(accountA, orgA))

        #expect(result == BringResult(moved: 1, kept: 1))
        #expect(fixture.sessionFiles() == [
            "\(accountA)/\(orgA)/local_b1.json",
            "\(accountA)/\(orgA)/local_dup.json",
            "\(accountB)/\(orgB)/local_dup.json",
        ])
    }

    @Test func bringingRefusesWhenClaudeIsOpenOrOnAnotherAccount() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        try fixture.addSession("local_b1", at: "\(accountB)/\(orgB)")
        let store = fixture.store()
        let sessions = store.sessionGroups(excluding: location(accountA, orgA)).flatMap(\.sessions)

        #expect(throws: AccountError.claudeRunning) {
            try fixture.store(claudeRunning: true).bring(sessions, to: location(accountA, orgA))
        }
        #expect(throws: AccountError.notSignedInto("Cuenta cccccccc")) {
            try store.bring(sessions, to: location(accountC, orgC))
        }
        #expect(fixture.sessionFiles() == ["\(accountB)/\(orgB)/local_b1.json"])
    }
}
