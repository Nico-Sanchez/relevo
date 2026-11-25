import AppKit
import RelevoCode
import SwiftUI

struct FocusRequest: Equatable {
    let accountID: String
    let session: Session.ID
}

@MainActor
@Observable
final class WindowModel {
    let id = UUID()
    let app: AppModel
    var selection: SidebarItem?
    var showingNewSession = false
    private(set) var accountID: String
    @ObservationIgnored weak var nsWindow: NSWindow?
    @ObservationIgnored var quoteSelection: (() -> Void)?

    init(app: AppModel, accountID: String?) {
        self.app = app
        self.accountID = accountID ?? app.accountForNewWindow.id
    }

    var account: ClaudeAccount {
        app.accounts.first { $0.id == accountID } ?? app.accounts.first ?? .standard
    }

    var visibleSessions: [Session] {
        app.sessions(of: account)
    }

    var visibleRecent: [PastSession] {
        app.recent(of: account)
    }

    var selected: Session? {
        guard case .open(let id) = selection else { return nil }
        return visibleSessions.first { $0.id == id }
    }

    var attentionElsewhere: Attention? {
        app.attention(otherThan: account)
    }

    func attach() {
        app.attach(id, account: account, viewing: selected?.id)
    }

    func detach() {
        app.detach(id)
    }

    func switchAccount(to account: ClaudeAccount) {
        accountID = account.id
        if selected == nil {
            selection = visibleSessions.first.map { .open($0.id) }
        }
        attach()
    }

    func reconcile() {
        if selected == nil, case .open = selection {
            selection = visibleSessions.first.map { .open($0.id) }
        }
    }

    func startSession(in folder: URL, account: ClaudeAccount, permissionMode: String, worktree: Bool) {
        place(app.startSession(in: folder, account: account, permissionMode: permissionMode, worktree: worktree), in: account)
    }

    func open(_ past: PastSession) {
        selection = .open(app.open(past, in: account).id)
    }

    func handOff(_ session: Session, to account: ClaudeAccount) {
        guard let moved = app.handOff(session, to: account) else { return }
        place(moved, in: account)
    }

    func handOff(_ past: PastSession, to account: ClaudeAccount) {
        place(app.handOff(past, to: account), in: account)
    }

    func close(_ session: Session) {
        app.close(session)
        reconcile()
    }

    func receive(_ request: FocusRequest?) {
        guard let request, request.accountID == accountID else { return }
        selection = .open(request.session)
        app.focusRequest = nil
        nsWindow?.makeKeyAndOrderFront(nil)
    }

    private func place(_ session: Session, in account: ClaudeAccount) {
        if account != self.account, app.hasWindow(for: account, besides: id) {
            app.focusRequest = FocusRequest(accountID: account.id, session: session.id)
            app.openWindow?(account.id)
            reconcile()
        } else {
            if account != self.account {
                switchAccount(to: account)
            }
            selection = .open(session.id)
        }
    }
}

struct WindowRoot: View {
    static let id = "account"

    let model: AppModel
    @Binding var accountID: String?
    @State private var window: WindowModel
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, accountID: Binding<String?>) {
        self.model = model
        _accountID = accountID
        _window = State(initialValue: WindowModel(app: model, accountID: accountID.wrappedValue))
    }

    var body: some View {
        ContentView(model: model, window: window)
            .frame(minWidth: 560, minHeight: 420)
            .focusedSceneValue(\.window, window)
            .task {
                await model.load()
                if model.isEmpty {
                    window.showingNewSession = true
                }
            }
            .onAppear {
                model.openWindow = { openWindow(id: Self.id, value: $0) }
                accountID = window.accountID
                window.attach()
                window.receive(model.focusRequest)
            }
            .onDisappear { window.detach() }
            .onChange(of: window.accountID) { _, current in accountID = current }
            .onChange(of: model.focusRequest) { _, request in window.receive(request) }
            .onChange(of: model.waitingCount, initial: true) { _, count in
                NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            }
    }
}

struct FocusedWindowKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var window: WindowModel? {
        get { self[FocusedWindowKey.self] }
        set { self[FocusedWindowKey.self] = newValue }
    }
}

struct WindowCommands: Commands {
    let model: AppModel
    @FocusedValue(\.window) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { window?.showingNewSession = true }
                .keyboardShortcut("n")
                .disabled(window == nil || model.executable == nil)
            Button("New Window") { openWindow(id: WindowRoot.id) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Button("Quote Selection") { window?.quoteSelection?() }
                .keyboardShortcut("'", modifiers: [.command, .shift])
                .disabled(window == nil)
        }
        CommandMenu("Account") {
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                if index < 9 {
                    Button(model.name(of: account)) { window?.switchAccount(to: account) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                        .disabled(window == nil)
                } else {
                    Button(model.name(of: account)) { window?.switchAccount(to: account) }
                        .disabled(window == nil)
                }
            }
            Divider()
            Menu("Open in New Window") {
                ForEach(model.accounts) { account in
                    Button(model.name(of: account)) { openWindow(id: WindowRoot.id, value: account.id) }
                }
            }
        }
    }
}

enum AccountTheme: String, CaseIterable, Identifiable {
    case orange, blue, green, purple, pink, teal, graphite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .orange: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .blue: Color(red: 0.26, green: 0.52, blue: 0.87)
        case .green: Color(red: 0.29, green: 0.61, blue: 0.30)
        case .purple: Color(red: 0.57, green: 0.48, blue: 0.85)
        case .pink: Color(red: 0.86, green: 0.38, blue: 0.58)
        case .teal: Color(red: 0.20, green: 0.62, blue: 0.64)
        case .graphite: Color(red: 0.50, green: 0.52, blue: 0.56)
        }
    }

    var name: String {
        switch self {
        case .orange: String(localized: "Orange")
        case .blue: String(localized: "Blue")
        case .green: String(localized: "Green")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .teal: String(localized: "Teal")
        case .graphite: String(localized: "Graphite")
        }
    }
}
