import AppKit
import ClaudeAccountsCore
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable {
        case home
        case switching(Account)
        case adding
        case bringing
    }

    let store = AccountStore()
    var snapshot = Snapshot.empty
    var screen = Screen.home
    var progress: String?
    var notice: String?
    var opensAtLogin = SMAppService.mainApp.status == .enabled

    func refresh() async {
        let store = store
        snapshot = await Task.detached { store.snapshot() }.value
    }

    func sessionGroups(excluding target: Location) async -> [SessionGroup] {
        let store = store
        return await Task.detached { store.sessionGroups(excluding: target) }.value
    }

    func switchTo(_ account: Account, bringing sessions: [SessionSummary]) async {
        await run(working: "Cambiando a \(account.name)…") { store in
            try store.switchTo(account.id)
            guard let target = account.location, !sessions.isEmpty else { return "Pasaste a \(account.name)." }
            return "Pasaste a \(account.name). \(try store.bring(sessions, to: target).summary)"
        }
    }

    func addAccount(named name: String) async {
        await run(working: "Guardando el login actual…") { store in
            try store.switchToNewAccount(named: name)
            return "Claude abrió sin sesión: entrá con \(name)."
        }
    }

    func bring(_ sessions: [SessionSummary], to target: Location) async {
        await run(working: "Moviendo sesiones…") { store in
            try store.bring(sessions, to: target).summary
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
        progress = "Cerrando Claude…"
        defer { progress = nil }
        guard await ClaudeApp.quit() else {
            show("Claude no se cerró. No cambié nada.")
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
            show(error.localizedDescription)
        }
        await refresh()
    }

    private func show(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Cuentas de Claude"
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

extension BringResult {
    var summary: String {
        var text = moved == 1 ? "Traje 1 sesión." : "Traje \(moved) sesiones."
        if kept == 1 {
            text += " 1 ya estaba ahí con el mismo id y no la toqué."
        } else if kept > 1 {
            text += " \(kept) ya estaban ahí con el mismo id y no las toqué."
        }
        return text
    }
}
