import Foundation
import RelevoCore
import Testing
@testable import RelevoUI

private let accountA = "aaaaaaaa-0000-0000-0000-000000000001"
private let accountB = "bbbbbbbb-0000-0000-0000-000000000002"
private let org = "11111111-0000-0000-0000-00000000000a"

final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func record() {
        lock.withLock { calls += 1 }
    }
}

@MainActor
@Suite struct UsageToggleTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "relevo-ui-\(UUID().uuidString)")
    let suite = "relevo-ui-tests-\(UUID().uuidString)"
    let counter = FetchCounter()

    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    func model(confirming answer: Bool = true) throws -> AppModel {
        let paths = DesktopPaths(
            data: root.appending(path: "data"),
            logs: root.appending(path: "logs"),
            storage: root.appending(path: "storage")
        )
        try write(["lastKnownAccountUuid": accountA], to: paths.data.appending(path: "config.json"))
        try write(["auth": [String: String](), "location": "\(accountB)/\(org)"],
                  to: paths.storage.appending(path: "profiles/\(accountB)/profile.json"))
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try "[LocalSessionManager] Initialization succeeded — accountId=\(accountA), orgId=\(org)\n"
            .write(to: paths.logs.appending(path: "main.log"), atomically: true, encoding: .utf8)

        let counter = counter
        let source = UsageSource(prepare: {}, fetch: { _ in
            counter.record()
            return Usage(windows: [UsageWindow(id: "five_hour", utilization: 10, resetsAt: nil)], fetchedAt: .now)
        })
        return AppModel(
            store: AccountStore(paths: paths, isClaudeRunning: { false }),
            usageSource: source,
            defaults: defaults,
            confirmUsage: { answer }
        )
    }

    func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test func usageStaysOffUntilTurnedOn() async throws {
        defer { cleanUp() }
        let model = try model()
        await model.refresh()

        await model.refreshUsage(force: true)

        #expect(!model.showsUsage)
        #expect(counter.count == 0)
        #expect(model.usage.isEmpty)
    }

    @Test func turningUsageOnReadsEveryAccountAndIsRemembered() async throws {
        defer { cleanUp() }
        let model = try model()
        await model.refresh()

        await model.setShowsUsage(true)

        #expect(model.showsUsage)
        #expect(counter.count == 2)
        #expect(Set(model.usage.keys) == [accountA, accountB])
        #expect(try self.model().showsUsage)
    }

    @Test func decliningTheWarningKeepsUsageOff() async throws {
        defer { cleanUp() }
        let model = try model(confirming: false)
        await model.refresh()

        await model.setShowsUsage(true)

        #expect(!model.showsUsage)
        #expect(counter.count == 0)
        #expect(!defaults.bool(forKey: "showsUsage"))
    }

    @Test func turningUsageOffForgetsWhatItRead() async throws {
        defer { cleanUp() }
        let model = try model()
        await model.refresh()
        await model.setShowsUsage(true)

        await model.setShowsUsage(false)
        await model.refreshUsage(force: true)

        #expect(model.usage.isEmpty)
        #expect(model.usageUpdatedAt == nil)
        #expect(counter.count == 2)
        #expect(!defaults.bool(forKey: "showsUsage"))
    }
}

@Suite struct DisplayTests {
    @Test func namesEveryUsageWindowReadably() {
        #expect(Display.windowName("extra_usage") != "extra_usage")
        #expect(Display.windowName("seven_day_oauth_apps").hasSuffix("Oauth apps"))
        #expect(Display.windowName("monthly_spend") == "Monthly spend")
    }
}
