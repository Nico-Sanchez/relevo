import AppKit
import RelevoCore
import Observation
import ServiceManagement

enum UsageState: Equatable, Sendable {
    case loading
    case loaded(Usage)
    case failed(String)
}

@MainActor
@Observable
public final class AppModel {
    public enum Screen: Equatable {
        case home
        case switching(Account)
        case adding
        case bringing
    }

    let store: AccountStore
    let usageSource: UsageSource
    public internal(set) var snapshot = Snapshot.empty
    public var screen = Screen.home
    var progress: String?
    var notice: String?
    var opensAtLogin = SMAppService.mainApp.status == .enabled
    var usage: [String: UsageState] = [:]
    var usageUpdatedAt: Date?
    var needsKeychainAccess = false

    public init(store: AccountStore = AccountStore(), usageSource: UsageSource? = nil) {
        self.store = store
        self.usageSource = usageSource ?? .claudeAI(store: store)
    }

    private var names: [String: String] {
        Dictionary(snapshot.accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    public func refresh() async {
        let store = store
        snapshot = await Task.detached { store.snapshot() }.value
    }

    public func refreshUsage(force: Bool = false) async {
        if !force, let usageUpdatedAt, Date.now.timeIntervalSince(usageUpdatedAt) < 60 { return }
        let accounts = snapshot.accounts.filter { $0.location != nil }
        guard !accounts.isEmpty else { return }
        usageUpdatedAt = .now
        do {
            try await usageSource.prepare()
            needsKeychainAccess = false
        } catch {
            needsKeychainAccess = true
            return
        }

        for account in accounts where usage[account.id] == nil {
            usage[account.id] = .loading
        }
        let source = usageSource
        let names = names
        await withTaskGroup(of: (String, UsageState).self) { group in
            for account in accounts {
                group.addTask {
                    do {
                        return (account.id, .loaded(try await source.fetch(account)))
                    } catch {
                        return (account.id, .failed(Display.message(for: error, names: names)))
                    }
                }
            }
            for await (id, state) in group {
                usage[id] = state
            }
        }
        usageUpdatedAt = .now
    }

    func sessionGroups(excluding target: Location) async -> [SessionGroup] {
        let store = store
        return await Task.detached { store.sessionGroups(excluding: target) }.value
    }

    func switchTo(_ account: Account, bringing sessions: [SessionSummary]) async {
        let name = account.displayName
        await run(working: String(localized: "Switching to \(name)…")) { store in
            try store.switchTo(account.id)
            let switched = String(localized: "Switched to \(name).")
            guard let target = account.location, !sessions.isEmpty else { return switched }
            return switched + " " + Display.summary(of: try store.bring(sessions, to: target))
        }
    }

    func addAccount(named name: String) async {
        await run(working: String(localized: "Saving the current login…")) { store in
            try store.switchToNewAccount(named: name)
            return String(localized: "Claude opened signed out: sign in with \(name).")
        }
    }

    func bring(_ sessions: [SessionSummary], to target: Location) async {
        await run(working: String(localized: "Moving sessions…")) { store in
            Display.summary(of: try store.bring(sessions, to: target))
        }
    }

    func rename(_ account: Account, to name: String) async {
        do {
            try store.rename(account.id, to: name)
        } catch {
            show(error.localizedDescription)
        }
        await refresh()
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            show(error.localizedDescription)
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func run(working message: String, _ operation: @escaping @Sendable (AccountStore) throws -> String) async {
        progress = String(localized: "Quitting Claude…")
        defer { progress = nil }
        guard await ClaudeApp.quit() else {
            show(String(localized: "Claude didn't quit. Nothing changed."))
            return
        }
        progress = message
        let store = store
        let outcome = await Task.detached { Result { try operation(store) } }.value
        ClaudeApp.launch()
        screen = .home
        switch outcome {
        case .success(let summary):
            notice = summary
        case .failure(let error):
            show(Display.message(for: error, names: names))
        }
        await refresh()
    }

    private func show(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Relevo"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@MainActor
enum ClaudeApp {
    static func quit() async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AccountStore.claudeBundleIdentifier)
        running.forEach { $0.terminate() }
        let deadline = Date.now.addingTimeInterval(60)
        while !running.allSatisfy(\.isTerminated), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return running.allSatisfy(\.isTerminated)
    }

    static func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AccountStore.claudeBundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
