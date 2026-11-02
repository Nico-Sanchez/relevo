import Foundation
import RelevoCore
import Testing
@testable import RelevoUI

private let account = "aaaaaaaa-0000-0000-0000-000000000001"
private let org = "11111111-0000-0000-0000-00000000000a"

@MainActor
final class FakeClaude {
    var running = true
    var quitsWhenAsked = false
    var quitRequests = 0
    var timesBroughtToFront = 0
    var launches = 0

    var app: ClaudeApp {
        ClaudeApp(
            isRunning: { self.running },
            requestQuit: {
                self.quitRequests += 1
                if self.quitsWhenAsked { self.running = false }
            },
            bringToFront: { self.timesBroughtToFront += 1 },
            launch: { self.launches += 1 },
            patience: .zero
        )
    }
}

@MainActor
@Suite struct ClaudeQuitTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "relevo-quit-\(UUID().uuidString)")
    let claude = FakeClaude()

    func model() async throws -> (AppModel, Location) {
        let paths = DesktopPaths(
            data: root.appending(path: "data"),
            logs: root.appending(path: "logs"),
            storage: root.appending(path: "storage")
        )
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account])
            .write(to: paths.data.appending(path: "config.json"))
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try "[LocalSessionManager] Initialization succeeded — accountId=\(account), orgId=\(org)\n"
            .write(to: paths.logs.appending(path: "main.log"), atomically: true, encoding: .utf8)
        let model = AppModel(
            store: AccountStore(paths: paths, isClaudeRunning: { false }),
            usageSource: UsageSource(prepare: {}, fetch: { _ in Usage(windows: [], fetchedAt: .now) }),
            defaults: UserDefaults(suiteName: "relevo-quit-\(UUID().uuidString)")!,
            confirmUsage: { false },
            claude: claude.app
        )
        await model.refresh()
        return (model, try #require(model.snapshot.current?.location))
    }

    func waitUntilClaudeRefuses(_ model: AppModel) async {
        while !model.waitingForClaude {
            await Task.yield()
        }
    }

    @Test func continuesRightAwayWhenClaudeQuits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        claude.quitsWhenAsked = true
        let (model, location) = try await model()

        await model.bring([], to: location)

        #expect(claude.quitRequests == 1)
        #expect(claude.timesBroughtToFront == 0)
        #expect(claude.launches == 1)
        #expect(model.progress == nil)
    }

    @Test func doesNotAskAClosedClaudeToQuit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        claude.running = false
        let (model, location) = try await model()

        await model.bring([], to: location)

        #expect(claude.quitRequests == 0)
        #expect(claude.launches == 1)
    }

    @Test func waitsForAClaudeThatRefusesAndContinuesWhenItCloses() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, location) = try await model()

        let bringing = Task { await model.bring([], to: location) }
        await waitUntilClaudeRefuses(model)

        #expect(claude.timesBroughtToFront == 1)
        #expect(claude.quitRequests == 1)
        #expect(claude.launches == 0)

        claude.running = false
        await bringing.value

        #expect(claude.launches == 1)
        #expect(!model.waitingForClaude)
        #expect(model.progress == nil)
    }

    @Test func cancellingLeavesClaudeOpenAndChangesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, location) = try await model()
        model.screen = .bringing

        let bringing = Task { await model.bring([], to: location) }
        await waitUntilClaudeRefuses(model)
        model.cancelQuit()
        await bringing.value

        #expect(claude.running)
        #expect(claude.launches == 0)
        #expect(!model.waitingForClaude)
        #expect(model.progress == nil)
        #expect(model.screen == .home)
        #expect(model.notice != nil)
    }

    @Test func cancellingTooLateStillFinishesTheSwitch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, location) = try await model()

        let bringing = Task { await model.bring([], to: location) }
        await waitUntilClaudeRefuses(model)
        claude.running = false
        model.cancelQuit()
        await bringing.value

        #expect(claude.launches == 1)
    }
}
