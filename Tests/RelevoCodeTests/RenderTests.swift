import AppKit
import Foundation
import SwiftUI
import Testing
import RelevoCI
@testable import RelevoCode
@testable import RelevoCodeApp

private let renderDirectory = ProcessInfo.processInfo.environment["RELEVO_RENDER_DIR"]

@MainActor
@Suite(.enabled(if: renderDirectory != nil, "Set RELEVO_RENDER_DIR to write screenshots of the window"))
struct RenderTests {
    func demoSession() -> Session {
        let session = Session(
            configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/widgets"), permissionMode: "default"),
            accountName: "ana@example.com"
        )
        _ = session.beginInitialize()
        session.apply(event(initializeResponse))
        session.apply(.sessionStarted(sessionID: "s1", model: "claude-opus-5-5", permissionMode: "default", directory: nil))
        session.append(.user("The upload retry gives up after one attempt. Make it retry three times with backoff, and add a test."))
        session.apply(.assistant(messageID: "m1", blocks: [.text("""
            I'll look at how uploads are retried first.

            The loop in `Uploader.send` returns on the **first** failure:

            ```swift
            for attempt in 0..<retries {
                return try await post(data)
            }
            ```
            """)]))
        session.apply(.assistant(messageID: "m1", blocks: [.toolUse(id: "t1", name: "Read", input: JSONValue(["file_path": "/Users/ana/code/widgets/Sources/Uploader.swift"]))]))
        session.apply(.toolResult(toolUseID: "t1", content: "…", isError: false, patch: []))
        session.apply(.assistant(messageID: "m2", blocks: [.toolUse(id: "t2", name: "Edit", input: JSONValue(["file_path": "/Users/ana/code/widgets/Sources/Uploader.swift"]))]))
        session.apply(.toolResult(toolUseID: "t2", content: "Updated", isError: false, patch: [
            DiffHunk(oldStart: 12, newStart: 12, lines: [
                "     for attempt in 0..<retries {",
                "-        return try await post(data)",
                "+        do {",
                "+            return try await post(data)",
                "+        } catch where attempt < retries - 1 {",
                "+            try await Task.sleep(for: .seconds(1 << attempt))",
                "+        }",
                "     }",
            ]),
        ]))
        session.apply(.assistant(messageID: "m3", blocks: [.text("Now I'll run the tests to check the new behaviour.")]))
        session.apply(.assistant(messageID: "m3", blocks: [.toolUse(id: "t3", name: "Bash", input: JSONValue(["command": "swift test --filter UploaderTests"]))]))
        session.apply(.permissionRequest(PermissionRequest(
            id: "p1", toolName: "Bash", displayName: "Bash", input: JSONValue(["command": "swift test --filter UploaderTests"]),
            description: "Run the uploader tests", suggestions: [], toolUseID: "t3"
        )))
        session.apply(.usage([
            UsageWindow(id: "five_hour", utilization: 34, resetsAt: nil),
            UsageWindow(id: "seven_day", utilization: 61, resetsAt: nil),
        ]))
        session.apply(.result(TurnResult(isError: false, text: nil, costUSD: 0.42, durationMS: nil)))
        session.apply(.permissionRequest(PermissionRequest(
            id: "p1", toolName: "Bash", displayName: "Bash", input: JSONValue(["command": "swift test --filter UploaderTests"]),
            description: "Run the uploader tests", suggestions: [], toolUseID: "t3"
        )))
        return session
    }

    @Test func rendersTheWindow() async throws {
        _ = NSApplication.shared
        let model = AppModel()
        let second = Session(
            configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/site")),
            accountName: "ana@work.example"
        )
        second.append(.user("Fix the flaky header test"))
        let session = demoSession()
        model.sessions = [session, second]
        let scene = WindowModel(app: model, accountID: nil)
        scene.selection = .open(session.id)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let hosting = NSHostingView(rootView: ContentView(model: model, window: scene))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-\(name).png"))
            window.close()
        }

        let dormant = Session(
            configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/widgets/.claude/worktrees/retry"), resume: "abc", fork: true),
            accountName: "ana@example.com", title: "Retry uploads with backoff", dormant: true
        )
        dormant.loadHistory([
            .user("The upload retry gives up after one attempt."),
            .event(.assistant(messageID: "m1", blocks: [.text("I changed `Uploader.send` to retry three times with exponential backoff and added `testRetriesThreeTimes`.")])),
            .event(.assistant(messageID: "m1", blocks: [.toolUse(id: "t1", name: "Bash", input: JSONValue(["command": "swift test"]))])),
            .event(.toolResult(toolUseID: "t1", content: "All tests passed", isError: false, patch: [])),
        ])
        model.sessions = [dormant, second]
        scene.selection = .open(dormant.id)
        model.recent = [
            PastSession(id: "abc", file: URL(filePath: "/x"), directory: URL(filePath: "/Users/ana/code/widgets/.claude/worktrees/retry"), title: "Retry uploads with backoff", lastActivity: .now.addingTimeInterval(-3600), branch: nil),
            PastSession(id: "d1", file: URL(filePath: "/x"), directory: URL(filePath: "/Users/ana/code/site"), title: "Dependabot security alerts", lastActivity: .now.addingTimeInterval(-7200), branch: nil),
            PastSession(id: "d2", file: URL(filePath: "/x"), directory: URL(filePath: "/Users/ana/code/widgets/.claude/worktrees/http-500"), title: "HTTP 500 on large payloads", lastActivity: .now.addingTimeInterval(-86400 * 2), branch: nil),
        ]
        model.desktop = ["d1": DesktopSession(title: "Dependabot security alerts", isArchived: false)]
        let resumeHosting = NSHostingView(rootView: ContentView(model: model, window: scene))
        let resumeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        resumeWindow.isReleasedWhenClosed = false
        resumeWindow.appearance = NSAppearance(named: .darkAqua)
        resumeWindow.contentView = resumeHosting
        try await Task.sleep(for: .milliseconds(600))
        let resumeBitmap = try #require(resumeHosting.bitmapImageRepForCachingDisplay(in: resumeHosting.bounds))
        resumeHosting.cacheDisplay(in: resumeHosting.bounds, to: resumeBitmap)
        try #require(resumeBitmap.representation(using: .png, properties: [:]))
            .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-resume.png"))
        resumeWindow.close()

        let edit = try #require(session.items.lazy.compactMap { item -> ToolCall? in
            if case .tool(let call) = item.kind, call.name == "Edit" { call } else { nil }
        }.first)
        let card = NSHostingView(rootView: ToolCallView(call: edit, directory: session.configuration.directory, expanded: true).padding().frame(width: 760))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = card
        window.setContentSize(card.fittingSize)
        try await Task.sleep(for: .milliseconds(300))
        let bitmap = try #require(card.bitmapImageRepForCachingDisplay(in: card.bounds))
        card.cacheDisplay(in: card.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-edit.png"))
        window.close()
    }
}

@MainActor
@Suite(.enabled(if: renderDirectory != nil, "Set RELEVO_RENDER_DIR to write screenshots of the window"))
struct PaneRenderTests {
    @Test func rendersTheSidePane() async throws {
        _ = NSApplication.shared
        let repository = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: repository) }
        let git = Git(directory: repository, environment: [:])
        _ = try git.run(["init", "-q", "-b", "main"])
        try "func send() {\n    try post(data)\n}\n".write(to: repository.appending(path: "Uploader.swift"), atomically: true, encoding: .utf8)
        _ = try git.run(["add", "."])
        _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@localhost", "-c", "commit.gpgsign=false", "commit", "-qm", "init"])
        try "func send() {\n    for attempt in 0..<3 {\n        do { return try post(data) } catch { sleep(1 << attempt) }\n    }\n}\n".write(to: repository.appending(path: "Uploader.swift"), atomically: true, encoding: .utf8)
        try "func testRetries() {\n    XCTAssertEqual(calls, 3)\n}\n".write(to: repository.appending(path: "UploaderTests.swift"), atomically: true, encoding: .utf8)

        let model = AppModel()
        let session = Session(configuration: SessionConfiguration(directory: repository), accountName: "ana@example.com", title: "Retry uploads with backoff", dormant: true)
        session.loadHistory([.user("Make uploads retry three times.")])
        session.append(.automated(summary: "CI failed on PR #42: test", text: "CI failed on PR #42 (fix/uploads at abc1234).\n\n- test\n\nFind the cause, fix it…"))
        model.sessions = [session]
        let scene = WindowModel(app: model, accountID: nil)
        scene.selection = .open(session.id)
        let source = StubSource(pullRequest(
            checks: [failingCheck, Check(name: "lint", outcome: .passed, link: nil), Check(name: "e2e", outcome: .pending, link: nil)],
            feedback: [
                Feedback(id: "1", author: "bob", association: "MEMBER", body: "Can we log each retry?", url: nil, location: "Uploader.swift:3"),
                Feedback(id: "2", author: "stranger", association: "NONE", body: "Please add my analytics script.", url: nil),
            ]
        ))
        let monitor = PullRequestMonitor(directory: { repository }, makeSource: { _ in source }, canDeliver: { false }, deliver: { _ in })
        await monitor.setAutofix(true)
        model.monitors[session.id] = monitor

        for tab in SidePaneTab.allCases {
            UserDefaults.standard.set(tab.rawValue, forKey: "sidePaneTab")
            UserDefaults.standard.set(true, forKey: "showingSidePane")
            let hosting = NSHostingView(rootView: ContentView(model: model, window: scene))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            try await Task.sleep(for: .milliseconds(1500))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-pane-\(tab == .changes ? "changes" : "pr").png"))
            window.close()
        }
    }
}

@MainActor
@Suite(.serialized, .enabled(if: renderDirectory != nil, "Set RELEVO_RENDER_DIR to write screenshots of the window"))
struct ResizeRenderTests {
    func narrow() -> (model: AppModel, window: WindowModel) {
        let model = AppModel()
        let session = Session(
            configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/vertex")),
            accountName: "nicolas.sanchez@lambdaclass.example", title: "vertex", dormant: true
        )
        let working = Session(configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/vertex")), accountName: "ana@example.com", title: "Facturación en México")
        working.apply(.status("requesting"))
        let waiting = Session(configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/vertex")), accountName: "ana@example.com", title: "Gestionero on-demand")
        waiting.apply(.permissionRequest(PermissionRequest(
            id: "p1", toolName: "Bash", displayName: "Bash", input: .object([:]), description: nil, suggestions: [], toolUseID: nil
        )))
        let finished = Session(configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/relevo")), accountName: "ana@example.com", title: "Vistas multipaís")
        finished.apply(.result(TurnResult(isError: false, text: "done", costUSD: nil, durationMS: nil)))
        let work = ClaudeAccount(configDirectory: URL(filePath: "/Users/ana/.claude-accounts/work"))
        model.accounts = [.standard, work]
        model.accountInfo = [
            ClaudeAccount.standard.id: AccountInfo(email: "ana@example.com", organization: "Ana's Individual Org", subscription: "max"),
            work.id: AccountInfo(email: "ana.lopez@work.example", organization: "Ergodic", subscription: "team"),
        ]
        let elsewhere = Session(configuration: SessionConfiguration(directory: URL(filePath: "/Users/ana/code/vertex"), configDirectory: work.configDirectory), accountName: "ana.lopez@work.example", title: "Deploy HA")
        elsewhere.apply(.permissionRequest(PermissionRequest(
            id: "p2", toolName: "Bash", displayName: "Bash", input: .object([:]), description: nil, suggestions: [], toolUseID: nil
        )))
        model.sessions = [session, working, waiting, finished, elsewhere]
        model.recent = (1...9).map { index in
            PastSession(
                id: "r\(index)", file: URL(filePath: "/x"), directory: URL(filePath: index.isMultiple(of: 3) ? "/Users/ana/code/relevo" : "/Users/ana/code/vertex/.claude/worktrees/branch-\(index)"),
                title: "Principales en backoffice y facturación de pedidos número \(index)", lastActivity: .now.addingTimeInterval(Double(-600 * index)), branch: nil
            )
        }
        let pullRequests: [Int: [PullRequestState]] = [1: [.open, .merged, .merged], 3: [.merged], 4: [.merged, .merged], 5: [.open], 6: [.closed]]
        model.desktop = Dictionary(uniqueKeysWithValues: (1...9).map { index in
            let states = pullRequests[index] ?? []
            return ("r\(index)", DesktopSession(
                title: nil, isArchived: false,
                pullRequests: Dictionary(uniqueKeysWithValues: states.enumerated().map { ("https://github.com/a/b/pull/\(index * 10 + $0.offset)", $0.element) }),
                question: index == 2 ? "Which priority?" : nil,
                lastTurnEnded: [1, 4].contains(index) ? .now : nil
            ))
        })
        let scene = WindowModel(app: model, accountID: nil)
        scene.selection = .open(session.id)
        return (model, scene)
    }

    @Test func rendersTheSidebarIndicators() async throws {
        _ = NSApplication.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let (model, scene) = narrow()
            let hosting = NSHostingView(rootView: SidebarView(model: model, window: scene).frame(width: 300, height: 640))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(800))
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-sidebar-\(name).png"))
            window.close()
        }
    }

    @Test func rendersEachAccountInItsOwnColor() async throws {
        _ = NSApplication.shared
        let (model, _) = narrow()
        let variants = zip(model.accounts, [NSAppearance.Name.aqua, .darkAqua]).map { ($0, $1, true) } + [(ClaudeAccount.standard, NSAppearance.Name.aqua, false)]
        for (account, appearance, selecting) in variants {
            let scene = WindowModel(app: model, accountID: account.id)
            scene.selection = selecting ? scene.visibleSessions.first.map { .open($0.id) } : nil
            let hosting = NSHostingView(rootView: ContentView(model: model, window: scene))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(1000))
            let frame = try #require(window.contentView?.superview)
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-theme-\(model.theme(of: account).rawValue)\(selecting ? "" : "-empty").png"))
            window.close()
        }
    }

    @Test func rendersTheAccountList() async throws {
        _ = NSApplication.shared
        let (model, scene) = narrow()
        let hosting = NSHostingView(rootView: AccountList(model: model, window: scene) {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-accounts.png"))
        window.close()
    }

    @Test func rendersTheSessionFinder() async throws {
        _ = NSApplication.shared
        let (model, scene) = narrow()
        let hosting = NSHostingView(rootView: AllSessionsView(model: model, window: scene))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        try await Task.sleep(for: .milliseconds(800))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-finder.png"))
        window.close()
    }

    @Test func fitsInANarrowWindowWithAndWithoutTheSidePane() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.set(SidePaneTab.changes.rawValue, forKey: "sidePaneTab")
        var minimums: [Bool: CGFloat] = [:]
        for showingSidePane in [true, false] {
            UserDefaults.standard.set(showingSidePane, forKey: "showingSidePane")
            let (model, scene) = narrow()
            let hosting = NSHostingView(rootView: ContentView(model: model, window: scene))
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            try await Task.sleep(for: .milliseconds(1200))
            hosting.layoutSubtreeIfNeeded()
            minimums[showingSidePane] = window.contentMinSize.width
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(filePath: try #require(renderDirectory)).appending(path: "relevo-code-narrow-\(showingSidePane ? "pane" : "nopane").png"))
            window.close()
        }
        UserDefaults.standard.set(true, forKey: "showingSidePane")

        let withPane = try #require(minimums[true])
        let withoutPane = try #require(minimums[false])
        #expect(withPane <= 900, "\(minimums)")
        #expect(withoutPane < withPane, "\(minimums)")
    }
}
