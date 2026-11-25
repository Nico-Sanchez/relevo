import Foundation
import Testing
import RelevoCI
@testable import RelevoCode
@testable import RelevoCodeApp

private let liveConfigDirectory = ProcessInfo.processInfo.environment["RELEVO_LIVE_CONFIG_DIR"]

@MainActor
@Suite(.enabled(if: liveConfigDirectory != nil, "Set RELEVO_LIVE_CONFIG_DIR to a signed-in Claude config folder"), .serialized)
struct LiveSessionTests {
    let account = URL(filePath: liveConfigDirectory ?? "/")
    let environment = ShellEnvironment.load()

    func waitUntil(seconds: Double = 120, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func makeFolder() throws -> (URL, String) {
        let token = "relevo-live-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appending(path: token)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, token)
    }

    func cleanUp(_ folder: URL, token: String) {
        try? FileManager.default.removeItem(at: folder)
        for pool in SessionLibrary.projectDirectories(for: [ClaudeAccount(configDirectory: account)]) {
            for project in (try? FileManager.default.contentsOfDirectory(at: pool, includingPropertiesForKeys: nil)) ?? []
            where project.lastPathComponent.contains(token) {
                try? FileManager.default.removeItem(at: project)
            }
        }
    }

    func session(_ configuration: SessionConfiguration, dormant: Bool = false) throws -> Session {
        Session(
            configuration: configuration, accountName: "live", environment: environment,
            executable: try #require(ShellEnvironment.claudeExecutable(in: environment)), dormant: dormant
        )
    }

    func lastReply(_ session: Session) -> String? {
        session.items.reversed().lazy.compactMap { item -> String? in
            if case .assistant(let text) = item.kind { text } else { nil }
        }.first
    }

    @Test func editsAFileAfterPermissionAndCanBeInterrupted() async throws {
        let (folder, token) = try makeFolder()
        defer { cleanUp(folder, token: token) }
        let session = try session(SessionConfiguration(directory: folder, configDirectory: account))
        defer { session.stop() }

        session.start()
        try await waitUntil { session.status == .idle }
        #expect(session.info?.account?.email != nil)

        session.send("Create a file named hello.txt containing exactly: hi. Use the Write tool. Then reply with one word: done.")
        try await waitUntil { !session.pendingPermissions.isEmpty || session.status == .idle }
        let permission = try #require(session.pendingPermissions.first)
        #expect(permission.toolName == "Write")
        #expect(permission.allowsEditsForSession)
        session.respond(permission, .allowEditsForSession)
        try await waitUntil { session.status == .idle }
        #expect(try String(contentsOf: folder.appending(path: "hello.txt"), encoding: .utf8) == "hi")
        #expect(session.sessionID != nil)
        #expect(session.cost > 0)

        var prompted = false
        session.send("Create a file named bye.txt containing exactly: bye. Use the Write tool. Then reply with one word: done.")
        try await waitUntil {
            if !session.pendingPermissions.isEmpty {
                prompted = true
                session.respond(session.pendingPermissions[0], .allow)
            }
            return session.status == .idle
        }
        #expect(!prompted)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "bye.txt").path))

        func bash() -> ToolCall? {
            session.items.compactMap { item -> ToolCall? in
                if case .tool(let call) = item.kind, call.name == "Bash" { call } else { nil }
            }.last
        }
        session.send("Run the shell command `sleep 60` with the Bash tool, then reply with one word: slept.")
        try await waitUntil { bash() != nil || session.status == .idle }
        let asked = !session.pendingPermissions.isEmpty
        let interruptedAt = Date.now
        session.interrupt()
        try await waitUntil(seconds: 40) { session.status == .idle }
        #expect(Date.now.timeIntervalSince(interruptedAt) < 30)
        #expect(bash()?.state != .done)
        if asked {
            #expect(bash()?.state == .denied)
        }
    }

    @Test func deliversAnAutomatedMessageToARunningSession() async throws {
        let (folder, token) = try makeFolder()
        defer { cleanUp(folder, token: token) }
        let session = try session(SessionConfiguration(directory: folder, configDirectory: account))
        defer { session.stop() }
        session.start()
        try await waitUntil { session.status == .idle }

        session.sendAutomated("CI failed on PR #1. This is a test of the delivery only: reply with one word, received, and do nothing else.", summary: "CI failed on PR #1: test")
        #expect(session.status == .working)
        try await waitUntil { session.status == .idle }

        #expect(session.items.first?.kind == .automated(summary: "CI failed on PR #1: test", text: "CI failed on PR #1. This is a test of the delivery only: reply with one word, received, and do nothing else."))
        #expect(lastReply(session)?.lowercased().contains("received") == true)
    }

    @Test func answersAQuestionFromClaude() async throws {
        let (folder, token) = try makeFolder()
        defer { cleanUp(folder, token: token) }
        let session = try session(SessionConfiguration(directory: folder, configDirectory: account, model: "haiku"))
        defer { session.stop() }
        session.start()
        try await waitUntil { session.status == .idle }

        session.send("Use the AskUserQuestion tool to ask me exactly one question: 'Which color do you prefer?' with the options Red and Blue. After I answer, reply with only the color I chose, nothing else.")
        try await waitUntil { session.pendingPermissions.first?.questions != nil }
        let request = try #require(session.pendingPermissions.first)
        let question = try #require(request.questions?.first)
        session.respond(request, .answer([question.question: "Blue"]))
        try await waitUntil { session.status == .idle }

        #expect(lastReply(session)?.lowercased().contains("blue") == true, "\(lastReply(session) ?? "no reply")")
    }

    @Test func steersATurnWithAMessageSentWhileItWorks() async throws {
        let (folder, token) = try makeFolder()
        defer { cleanUp(folder, token: token) }
        let session = try session(SessionConfiguration(directory: folder, configDirectory: account, model: "haiku", permissionMode: "acceptEdits"))
        defer { session.stop() }
        session.start()
        try await waitUntil { session.status == .idle }

        session.send("Use the Bash tool to run `sleep 6 && echo first-done`, then reply with exactly the word FIRST and nothing else.")
        try await waitUntil {
            if let request = session.pendingPermissions.first {
                session.respond(request, .allow)
            }
            return session.items.contains { item in
                if case .tool(let call) = item.kind { call.name == "Bash" } else { false }
            }
        }
        session.send("Second message: after you are done, also reply with exactly the word SECOND.")
        #expect(session.steering.count == 1)
        try await waitUntil { session.status == .idle && session.steering.isEmpty }

        #expect(lastReply(session)?.contains("SECOND") == true)
    }

    @Test func changesModelEffortAndModeWhileRunning() async throws {
        let (folder, token) = try makeFolder()
        defer { cleanUp(folder, token: token) }
        let session = try session(SessionConfiguration(directory: folder, configDirectory: account))
        defer { session.stop() }
        session.start()
        try await waitUntil { session.status == .idle }

        session.setModel("sonnet")
        session.setEffort("low")
        session.setPermissionMode("acceptEdits")
        session.setModel("not-a-real-model")
        try await Task.sleep(for: .seconds(3))
        session.setModel("sonnet")
        session.send("Reply with one word: ok.")
        try await waitUntil { session.status == .idle }

        #expect(session.model?.contains("sonnet") == true, "\(session.model ?? "nil")")
        #expect(session.permissionMode == "acceptEdits")
        let refused = session.items.compactMap { item -> Notice.Setting? in
            if case .notice(.refused(let setting, _)) = item.kind { setting } else { nil }
        }
        #expect(refused == [.model], "\(session.items)")
    }

    @Test func continuesAPastSessionFromDiskAsACopy() async throws {
        let (folder, token) = try makeFolder()
        defer { cleanUp(folder, token: token) }
        try "hi\n".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "a.txt"], ["-c", "user.name=t", "-c", "user.email=t@localhost", "-c", "commit.gpgsign=false", "commit", "-qm", "init"]] {
            let git = Process()
            git.executableURL = URL(filePath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = folder
            try git.run()
            git.waitUntilExit()
        }

        let first = try session(SessionConfiguration(directory: folder, configDirectory: account, worktree: "relevo-live"))
        first.start()
        try await waitUntil { first.status == .idle }
        first.send("Remember the word pomelo. Reply with one word: ok.")
        try await waitUntil { first.status == .idle && first.sessionID != nil }
        first.stop()
        let id = try #require(first.sessionID)
        #expect(first.workingDirectory.path.hasSuffix(".claude/worktrees/relevo-live"))

        let pools = SessionLibrary.projectDirectories(for: [ClaudeAccount(configDirectory: account)])
        let past = try #require(SessionLibrary.recent(in: pools, limit: 30).first { $0.id == id })
        #expect(past.directory.resolvingSymlinksInPath() == first.workingDirectory.resolvingSymlinksInPath())
        #expect(past.projectName.hasSuffix("· relevo-live"))

        let resumed = try session(SessionConfiguration(directory: past.directory, configDirectory: account, resume: id, fork: true), dormant: true)
        defer { resumed.stop() }
        resumed.loadHistory(History.entries(in: past.file))
        #expect(resumed.items.contains { $0.kind == .user("Remember the word pomelo. Reply with one word: ok.") })
        #expect(resumed.status == .dormant)

        resumed.send("Which word did I ask you to remember? Reply with only that word.")
        try await waitUntil { resumed.status == .idle }
        #expect(lastReply(resumed)?.lowercased().contains("pomelo") == true)
        #expect(resumed.sessionID != nil)
        #expect(resumed.sessionID != id)
    }
}

private let livePullRequestDirectory = ProcessInfo.processInfo.environment["RELEVO_LIVE_PR_DIR"]

@MainActor
@Suite(.enabled(if: livePullRequestDirectory != nil, "Set RELEVO_LIVE_PR_DIR to a checkout whose branch has a pull request"))
struct LivePullRequestTests {
    @Test func readsThePullRequestThroughTheLoginShellEnvironment() async throws {
        let monitor = PullRequestMonitor(
            directory: { URL(filePath: livePullRequestDirectory ?? "/") },
            makeSource: { [environment = ShellEnvironment.load()] in GitHubCLI(directory: $0, environment: environment) },
            canDeliver: { false },
            deliver: { _ in }
        )

        await monitor.refresh()

        let pullRequest = try #require(monitor.pullRequest, "\(monitor.state)")
        #expect(pullRequest.isOpen)
        #expect(!pullRequest.checks.isEmpty)
    }
}
