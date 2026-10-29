import AppKit
import RelevoCore
import RelevoUI
import SwiftUI

enum Demo {
    static let ada = "a1a1a1a1-0000-4000-8000-000000000001"
    static let grace = "b2b2b2b2-0000-4000-8000-000000000002"
    static let alan = "c3c3c3c3-0000-4000-8000-000000000003"
    static let acme = "e5e5e5e5-0000-4000-8000-000000000005"
    static let personal = "d4d4d4d4-0000-4000-8000-000000000004"

    static let usage: [String: [UsageWindow]] = [
        ada: [
            UsageWindow(id: "five_hour", utilization: 34, resetsAt: .now.addingTimeInterval(2 * 3600)),
            UsageWindow(id: "seven_day", utilization: 72, resetsAt: .now.addingTimeInterval(3 * 86400)),
            UsageWindow(id: "seven_day_opus", utilization: 15, resetsAt: .now.addingTimeInterval(3 * 86400)),
        ],
        grace: [
            UsageWindow(id: "five_hour", utilization: 8, resetsAt: .now.addingTimeInterval(4 * 3600)),
            UsageWindow(id: "seven_day", utilization: 91, resetsAt: .now.addingTimeInterval(86400)),
        ],
        alan: [
            UsageWindow(id: "five_hour", utilization: 0, resetsAt: nil),
            UsageWindow(id: "seven_day", utilization: 18, resetsAt: .now.addingTimeInterval(5 * 86400)),
        ],
    ]

    static let sessions: [(account: String, org: String, title: String, minutesAgo: Double)] = [
        (ada, acme, "Refactor the billing webhooks", 2),
        (ada, acme, "Fix the flaky checkout test", 14),
        (ada, acme, "Add dark mode to settings", 47),
        (ada, acme, "Migrate CI to arm64 runners", 180),
        (ada, acme, "Investigate the worker memory leak", 1440),
        (ada, acme, "Write the onboarding guide", 2880),
        (grace, acme, "Prototype vector search", 2900),
        (alan, personal, "Plan the trip to Lisbon", 7200),
    ]

    static func install(in root: URL) throws -> DesktopPaths {
        let paths = DesktopPaths(
            data: root.appending(path: "data"),
            logs: root.appending(path: "logs"),
            storage: root.appending(path: "storage")
        )
        try write(["lastKnownAccountUuid": ada], to: paths.data.appending(path: "config.json"))
        try write(
            [
                "accounts": [ada: "ada@example.com", grace: "grace@example.com", alan: "alan@example.com"],
                "orgs": [acme: "Acme", personal: "Personal"],
            ],
            to: paths.storage.appending(path: "labels.json")
        )
        for (account, org) in [(grace, acme), (alan, personal)] {
            try write(["auth": [String: String](), "location": "\(account)/\(org)"],
                      to: paths.storage.appending(path: "profiles/\(account)/profile.json"))
        }
        for (index, session) in sessions.enumerated() {
            let lastActivity = Date.now.addingTimeInterval(-session.minutesAgo * 60).timeIntervalSince1970 * 1000
            try write(
                ["title": session.title, "lastActivityAt": lastActivity, "isArchived": false],
                to: paths.data.appending(path: "claude-code-sessions/\(session.account)/\(session.org)/local_demo\(index).json")
            )
        }
        let log = "[LocalSessionManager] Initialization succeeded — accountId=\(ada), orgId=\(acme), existingSessions=6\n"
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try log.write(to: paths.logs.appending(path: "main.log"), atomically: true, encoding: .utf8)
        return paths
    }

    private static func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}

@MainActor
final class Renderer: NSObject, NSApplicationDelegate {
    let output: URL
    let language: String
    let screens: [String]

    init(output: URL, language: String, screens: [String]) {
        self.output = output
        self.language = language
        self.screens = screens
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let root = FileManager.default.temporaryDirectory.appending(path: "relevo-demo-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let store = AccountStore(paths: try Demo.install(in: root), isClaudeRunning: { false })
                let usage = UsageSource(prepare: {}, fetch: { account in
                    Usage(windows: Demo.usage[account.id] ?? [], fetchedAt: .now)
                })
                let model = AppModel(store: store, usageSource: usage)
                await model.refresh()
                await model.refreshUsage(force: true)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    for screen in screens {
                        try await render(screen, model: model, appearance: appearance)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    private func render(_ screen: String, model: AppModel, appearance: NSAppearance.Name) async throws {
        switch screen {
        case "switch":
            guard let grace = model.snapshot.others.first(where: { $0.id == Demo.grace }) else { return }
            model.screen = .switching(grace)
        case "add":
            model.screen = .adding
        default:
            model.screen = .home
        }
        let content = MenuView(model: model)
            .frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .padding(36)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 412, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(2))
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let theme = appearance == .darkAqua ? "dark" : "light"
        try bitmap.representation(using: .png, properties: [:])?
            .write(to: output.appending(path: "\(screen)-\(language)-\(theme).png"))
    }
}

@main
struct Screenshots {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        let renderer = Renderer(
            output: URL(fileURLWithPath: arguments[1]),
            language: arguments[2],
            screens: arguments.dropFirst(3).prefix { !$0.hasPrefix("-") }.map { $0 }
        )
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = renderer
        app.run()
    }
}
