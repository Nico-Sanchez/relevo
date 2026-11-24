import AppKit
import RelevoCode
import SwiftUI

@main
struct RelevoCodeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Relevo Code") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 420)
                .task { await model.load() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.showingNewSession = true }
                    .keyboardShortcut("n")
            }
        }
    }
}

enum SidebarItem: Hashable {
    case open(Session.ID)
    case recent(String)
}

@MainActor
@Observable
final class AppModel {
    var sessions: [Session] = []
    var selection: SidebarItem?
    var accounts: [ClaudeAccount]
    var accountInfo: [String: AccountInfo] = [:]
    var recent: [PastSession] = []
    var desktop: [String: DesktopSession] = [:]
    var environment: [String: String]?
    var executable: URL?
    var problem: String?
    var showingNewSession = false
    var monitors: [Session.ID: PullRequestMonitor] = [:]

    private let defaults = UserDefaults.standard

    init() {
        accounts = [.standard] + (defaults.stringArray(forKey: "accountFolders") ?? []).map {
            ClaudeAccount(configDirectory: URL(filePath: $0))
        }
    }

    var selected: Session? {
        guard case .open(let id) = selection else { return nil }
        return sessions.first { $0.id == id }
    }

    var recentNotOpen: [PastSession] {
        let open = Set(sessions.compactMap(\.sessionID))
        return recent.filter { !open.contains($0.id) }
    }

    var lastFolder: URL? {
        get { defaults.string(forKey: "lastFolder").map { URL(filePath: $0) } }
        set { defaults.set(newValue?.path, forKey: "lastFolder") }
    }

    var lastAccountID: String? {
        get { defaults.string(forKey: "lastAccount") }
        set { defaults.set(newValue, forKey: "lastAccount") }
    }

    var lastPermissionMode: String {
        get { defaults.string(forKey: "lastPermissionMode") ?? "default" }
        set { defaults.set(newValue, forKey: "lastPermissionMode") }
    }

    var preferredAccount: ClaudeAccount {
        accounts.first { $0.id == lastAccountID } ?? .standard
    }

    func load() async {
        let environment = await Task.detached { ShellEnvironment.load() }.value
        self.environment = environment
        executable = ShellEnvironment.claudeExecutable(in: environment)
        if executable == nil {
            problem = String(localized: "Claude Code isn't installed, or it isn't on your shell's PATH.")
            return
        }
        await refreshAccounts()
        await refreshRecent()
        if sessions.isEmpty, recent.isEmpty {
            showingNewSession = true
        }
    }

    func refreshAccounts() async {
        guard let executable, let environment else { return }
        for account in accounts {
            accountInfo[account.id] = await account.status(executable: executable, environment: environment)
        }
    }

    func refreshRecent() async {
        let directories = SessionLibrary.projectDirectories(for: accounts)
        let (recent, desktop) = await Task.detached {
            (SessionLibrary.recent(in: directories), SessionLibrary.desktopSessions())
        }.value
        self.recent = recent
        self.desktop = desktop
    }

    func name(of account: ClaudeAccount) -> String {
        accountInfo[account.id]?.email ?? account.folderName
    }

    func account(named configDirectory: URL?) -> ClaudeAccount {
        accounts.first { $0.configDirectory == configDirectory } ?? ClaudeAccount(configDirectory: configDirectory)
    }

    func addAccountFolder(_ folder: URL) async {
        let account = ClaudeAccount(configDirectory: folder)
        guard !accounts.contains(account) else { return }
        accounts.append(account)
        defaults.set(accounts.compactMap { $0.configDirectory?.path }, forKey: "accountFolders")
        await refreshAccounts()
        await refreshRecent()
    }

    func startSession(in folder: URL, account: ClaudeAccount, permissionMode: String, worktree: Bool) {
        let configuration = SessionConfiguration(
            directory: folder, configDirectory: account.configDirectory, permissionMode: permissionMode,
            worktree: worktree ? "session-\(UUID().uuidString.prefix(6).lowercased())" : nil
        )
        let session = Session(configuration: configuration, accountName: name(of: account), environment: environment ?? [:], executable: executable)
        show(session)
        lastFolder = folder
        lastAccountID = account.id
        lastPermissionMode = permissionMode
        session.start()
    }

    func open(_ past: PastSession, in account: ClaudeAccount? = nil) {
        if let existing = sessions.first(where: { $0.sessionID == past.id }) {
            selection = .open(existing.id)
            return
        }
        let account = account ?? preferredAccount
        let configuration = SessionConfiguration(
            directory: past.directory, configDirectory: account.configDirectory, resume: past.id,
            fork: isOpenInDesktop(past.id), permissionMode: lastPermissionMode
        )
        let session = Session(
            configuration: configuration, accountName: name(of: account), environment: environment ?? [:], executable: executable,
            title: past.title, dormant: true
        )
        show(session)
        Task {
            let entries = await Task.detached { History.entries(in: past.file) }.value
            session.loadHistory(entries)
        }
    }

    func continueSession(_ session: Session, in account: ClaudeAccount) {
        guard let copy = session.continuation(configDirectory: account.configDirectory, accountName: name(of: account)) else { return }
        show(copy)
    }

    func isOpenInDesktop(_ id: String?) -> Bool {
        guard let id, let session = desktop[id] else { return false }
        return !session.isArchived
    }

    func close(_ session: Session) {
        session.stop()
        monitors.removeValue(forKey: session.id)?.stop()
        sessions.removeAll { $0.id == session.id }
        if selection == .open(session.id) {
            selection = sessions.first.map { .open($0.id) }
        }
    }

    private func show(_ session: Session) {
        sessions.insert(session, at: 0)
        selection = .open(session.id)
        let monitor = PullRequestMonitor(session: session, environment: environment ?? [:])
        monitors[session.id] = monitor
        monitor.start()
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            if let session = model.selected {
                SessionView(session: session, model: model)
                    .id(session.id)
            } else if let problem = model.problem {
                ContentUnavailableView("Can't start Claude Code", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                ContentUnavailableView {
                    Label("No session", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Start a new session, or pick a recent one to continue it.")
                } actions: {
                    Button("New Session") { model.showingNewSession = true }
                        .disabled(model.executable == nil)
                }
            }
        }
        .sheet(isPresented: $model.showingNewSession) {
            NewSessionView(model: model)
        }
        .onChange(of: model.selection) {
            if case .recent(let id) = model.selection, let past = model.recent.first(where: { $0.id == id }) {
                model.open(past)
            }
        }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            if !model.sessions.isEmpty {
                Section("Open") {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session)
                            .tag(SidebarItem.open(session.id))
                            .contextMenu {
                                ContinueMenu(model: model, session: session)
                                Divider()
                                Button("Close Session") { model.close(session) }
                            }
                    }
                }
            }
            Section("Recent") {
                ForEach(model.recentNotOpen) { past in
                    RecentRow(past: past, inDesktop: model.isOpenInDesktop(past.id))
                        .tag(SidebarItem.recent(past.id))
                        .contextMenu {
                            Menu("Continue in") {
                                ForEach(model.accounts) { account in
                                    Button(model.name(of: account)) { model.open(past, in: account) }
                                }
                            }
                        }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshRecent() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    model.showingNewSession = true
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .disabled(model.executable == nil)
            }
        }
    }
}

struct ContinueMenu: View {
    let model: AppModel
    let session: Session

    var body: some View {
        Menu("Continue in Another Account") {
            ForEach(model.accounts) { account in
                Button(model.name(of: account)) { model.continueSession(session, in: account) }
                    .disabled(account.configDirectory == session.configuration.configDirectory)
            }
        }
        .disabled(session.sessionID == nil)
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(status: session.status)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(verbatim: "\(session.workingDirectory.lastPathComponent) · \(session.accountName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecentRow: View {
    let past: PastSession
    let inDesktop: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(past.title)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(past.projectName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                Text(past.lastActivity, format: .relative(presentation: .named))
                    .lineLimit(1)
                if inDesktop {
                    Text("Desktop")
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                        .help("Still open in Claude Desktop")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.leading, 22)
    }
}

struct StatusIndicator: View {
    let status: Session.Status

    var body: some View {
        switch status {
        case .starting, .working:
            ProgressView()
                .controlSize(.mini)
        case .waitingForPermission:
            Circle().fill(.orange).frame(width: 8, height: 8)
                .help("Waiting for your permission")
        case .idle:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .dormant:
            Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
                .help("Not running: your next message continues it")
        case .ended:
            Circle().fill(.secondary).frame(width: 8, height: 8)
        }
    }
}

struct NewSessionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var accountID = ClaudeAccount.standard.id
    @State private var permissionMode = "default"
    @State private var worktree = false

    static var modes: [(String, String)] {
        [
            ("default", String(localized: "Ask before acting")),
            ("acceptEdits", String(localized: "Accept edits")),
            ("plan", String(localized: "Plan only")),
            ("bypassPermissions", String(localized: "Bypass permissions")),
        ]
    }

    private var isRepository: Bool {
        folder.map { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) } ?? false
    }

    var body: some View {
        Form {
            LabeledContent("Folder") {
                HStack {
                    Text(folder?.path ?? String(localized: "None"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(folder == nil ? .secondary : .primary)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Toggle("Work in a new worktree", isOn: $worktree)
                .disabled(!isRepository)
                .help("Creates .claude/worktrees/<name> on its own branch, like Claude Desktop does")
            Picker("Account", selection: $accountID) {
                ForEach(model.accounts) { account in
                    Text(model.name(of: account)).tag(account.id)
                }
            }
            HStack {
                Spacer()
                Button("Add account folder…") { addAccount() }
                    .buttonStyle(.link)
            }
            Picker("Permissions", selection: $permissionMode) {
                ForEach(Self.modes, id: \.0) { mode in
                    Text(mode.1).tag(mode.0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    guard let folder, let account = model.accounts.first(where: { $0.id == accountID }) else { return }
                    model.startSession(in: folder, account: account, permissionMode: permissionMode, worktree: worktree && isRepository)
                    dismiss()
                }
                .disabled(folder == nil)
            }
        }
        .onAppear {
            folder = model.lastFolder
            permissionMode = model.lastPermissionMode
            accountID = model.preferredAccount.id
            worktree = isRepository
        }
        .onChange(of: folder) {
            worktree = isRepository
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.directoryURL = folder
        if panel.runModal() == .OK {
            folder = panel.url
        }
    }

    private func addAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a Claude Code config folder (the CLAUDE_CONFIG_DIR of a signed-in account)."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.addAccountFolder(url)
            accountID = ClaudeAccount(configDirectory: url).id
        }
    }
}
