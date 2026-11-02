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

    static let showsUsageKey = "showsUsage"

    let store: AccountStore
    let usageSource: UsageSource
    let defaults: UserDefaults
    let confirmUsage: @MainActor () -> Bool
    let claude: ClaudeApp
    public internal(set) var snapshot = Snapshot.empty
    public private(set) var showsUsage: Bool
    public var screen = Screen.home
    var progress: String?
    var waitingForClaude = false
    var notice: String?
    var opensAtLogin = SMAppService.mainApp.status == .enabled
    var usage: [String: UsageState] = [:]
    var usageUpdatedAt: Date?
    var needsKeychainAccess = false
    private var quitting: Task<Bool, Never>?

    public init(
        store: AccountStore = AccountStore(),
        usageSource: UsageSource? = nil,
        defaults: UserDefaults = .standard,
        confirmUsage: (@MainActor () -> Bool)? = nil,
        claude: ClaudeApp = .installed()
    ) {
        self.store = store
        self.usageSource = usageSource ?? .claudeAI(store: store)
        self.defaults = defaults
        self.confirmUsage = confirmUsage ?? AppModel.askToShowUsage
        self.claude = claude
        showsUsage = defaults.bool(forKey: Self.showsUsageKey)
    }

    private var names: [String: String] {
        Dictionary(snapshot.accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    public func refresh() async {
        let store = store
        snapshot = await Task.detached { store.snapshot() }.value
    }

    public func setShowsUsage(_ enabled: Bool) async {
        if enabled, !showsUsage, !confirmUsage() {
            return
        }
        showsUsage = enabled
        defaults.set(enabled, forKey: Self.showsUsageKey)
        if enabled {
            await refreshUsage(force: true)
        } else {
            usage = [:]
            usageUpdatedAt = nil
            needsKeychainAccess = false
        }
    }

    public func refreshUsage(force: Bool = false) async {
        guard showsUsage else { return }
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

    func cancelQuit() {
        quitting?.cancel()
    }

    private func run(working message: String, _ operation: @escaping @Sendable (AccountStore) throws -> String) async {
        progress = String(localized: "Quitting Claude…")
        defer { progress = nil }
        let quitting = Task { await claude.quit { self.waitingForClaude = true } }
        self.quitting = quitting
        let quit = await quitting.value
        waitingForClaude = false
        guard quit else {
            screen = .home
            notice = String(localized: "Nothing changed. If Claude is still asking whether to quit, cancel it there too.")
            return
        }
        progress = message
        let store = store
        let outcome = await Task.detached { Result { try operation(store) } }.value
        claude.launch()
        screen = .home
        switch outcome {
        case .success(let summary):
            notice = summary
        case .failure(let error):
            show(Display.message(for: error, names: names))
        }
        await refresh()
    }

    static func askToShowUsage() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Show each account's usage?")
        alert.informativeText = String(localized: "Relevo will read each account's session from Claude Desktop and ask claude.ai for its usage, at most once a minute while the menu is open. Anthropic's terms don't allow automated access to Claude outside its API, so you use this at your own risk. macOS will ask for access to the “Claude Safe Storage” keychain item.")
        alert.addButton(withTitle: String(localized: "Show usage"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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

public struct ClaudeApp: Sendable {
    typealias Action = @MainActor @Sendable () -> Void

    let isRunning: @MainActor @Sendable () -> Bool
    let requestQuit: Action
    let bringToFront: Action
    let launch: Action
    var patience: Duration = .seconds(2)

    public static func installed(bundleIdentifier: String = AccountStore.claudeBundleIdentifier) -> ClaudeApp {
        let instances: @MainActor @Sendable () -> [NSRunningApplication] = {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        }
        return ClaudeApp(
            isRunning: { !instances().isEmpty },
            requestQuit: { instances().forEach { $0.terminate() } },
            bringToFront: { instances().forEach { $0.activate(from: .current) } },
            launch: {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        )
    }

    @MainActor
    func quit(onRefused: () -> Void) async -> Bool {
        guard isRunning() else { return true }
        requestQuit()
        let patienceEnds = ContinuousClock.now + patience
        var refused = false
        while isRunning() {
            if !refused, ContinuousClock.now >= patienceEnds {
                refused = true
                bringToFront()
                onRefused()
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return !isRunning()
            }
        }
        return true
    }
}
