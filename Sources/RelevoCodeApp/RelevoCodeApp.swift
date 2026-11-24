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
    var seen: [String: Date]
    private(set) var seenOpen: [Session.ID: Date] = [:]

    private let defaults = UserDefaults.standard

    init() {
        accounts = [.standard] + (defaults.stringArray(forKey: "accountFolders") ?? []).map {
            ClaudeAccount(configDirectory: URL(filePath: $0))
        }
        seen = ((defaults.dictionary(forKey: "seenSessions") as? [String: Double]) ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
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
        keepRecentFresh()
    }

    private func keepRecentFresh() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                await self.refreshRecent()
            }
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
            let desktop = SessionLibrary.desktopSessions()
            return (SessionLibrary.relevant(SessionLibrary.recent(in: directories, limit: 300), desktop: desktop), desktop)
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

    func markSeen(_ item: SidebarItem?) {
        guard case .open(let id) = item, let session = sessions.first(where: { $0.id == id }) else { return }
        seenOpen[id] = .now
        guard let sessionID = session.sessionID else { return }
        let cutoff = Date.now.addingTimeInterval(-60 * 86_400)
        seen[sessionID] = .now
        seen = seen.filter { $0.value > cutoff }
        defaults.set(seen.mapValues(\.timeIntervalSince1970), forKey: "seenSessions")
    }

    func attention(of session: Session) -> Attention? {
        if session.status == .waitingForPermission {
            return .waiting
        }
        guard selection != .open(session.id), let ended = session.lastTurnEnded else { return nil }
        return ended > (seenOpen[session.id] ?? .distantPast) ? .unread : nil
    }

    func attention(of past: PastSession) -> Attention? {
        past.attention(desktop: desktop[past.id], seen: seen[past.id])
    }

    func pullRequests(of session: Session) -> PullRequestBadge? {
        var states = session.sessionID.flatMap { desktop[$0]?.pullRequests } ?? [:]
        if let pullRequest = monitors[session.id]?.pullRequest, let state = PullRequestState(rawValue: pullRequest.state) {
            states[pullRequest.url] = state
        }
        return PullRequestBadge(states.values)
    }

    func pullRequests(of past: PastSession) -> PullRequestBadge? {
        desktop[past.id].flatMap { PullRequestBadge($0.pullRequests.values) }
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
        .onChange(of: model.selection) { previous, current in
            model.markSeen(previous)
            model.markSeen(current)
            if case .recent(let id) = current, let past = model.recent.first(where: { $0.id == id }) {
                model.open(past)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshRecent() }
        }
    }
}

struct SidebarView: View {
    static let recentLimit = 8

    @Bindable var model: AppModel
    @AppStorage("recentExpanded") private var recentExpanded = true
    @State private var showingAllSessions = false

    var body: some View {
        List(selection: $model.selection) {
            if !model.sessions.isEmpty {
                Section("Open") {
                    ForEach(model.sessions) { session in
                        SidebarRow(
                            pullRequests: model.pullRequests(of: session),
                            attention: model.attention(of: session),
                            working: session.status == .working || session.status == .starting
                        ) {
                            SessionRow(session: session)
                        } actions: {
                            OpenSessionMenu(model: model, session: session)
                        }
                        .tag(SidebarItem.open(session.id))
                    }
                }
            }
            Section("Recent", isExpanded: $recentExpanded) {
                ForEach(model.recentNotOpen.prefix(Self.recentLimit)) { past in
                    SidebarRow(pullRequests: model.pullRequests(of: past), attention: model.attention(of: past)) {
                        RecentRow(past: past)
                    } actions: {
                        RecentSessionMenu(model: model, past: past)
                    }
                    .tag(SidebarItem.recent(past.id))
                }
                if model.recentNotOpen.count > Self.recentLimit {
                    Button {
                        showingAllSessions = true
                    } label: {
                        Text("See all \(model.recentNotOpen.count)…")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showingAllSessions) {
            AllSessionsView(model: model)
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

struct OpenSessionMenu: View {
    let model: AppModel
    let session: Session

    var body: some View {
        ContinueMenu(model: model, session: session)
        Divider()
        Button("Close Session") { model.close(session) }
    }
}

struct RecentSessionMenu: View {
    let model: AppModel
    let past: PastSession

    var body: some View {
        Menu("Continue in") {
            ForEach(model.accounts) { account in
                Button(model.name(of: account)) { model.open(past, in: account) }
            }
        }
    }
}

struct SidebarRow<Content: View, Actions: View>: View {
    let pullRequests: PullRequestBadge?
    let attention: Attention?
    let working: Bool
    let content: Content
    let actions: Actions
    @State private var hovering = false

    init(
        pullRequests: PullRequestBadge?, attention: Attention?, working: Bool = false,
        @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions
    ) {
        self.pullRequests = pullRequests
        self.attention = attention
        self.working = working
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 6) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if let pullRequests {
                PullRequestIcon(badge: pullRequests)
            }
            Group {
                if hovering {
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    StatusDot(attention: attention, working: working)
                }
            }
            .frame(width: 18)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions }
    }
}

struct StatusDot: View {
    static let waiting = Color(red: 0.96, green: 0.74, blue: 0.24)
    static let unread = Color(red: 0.26, green: 0.52, blue: 0.87)

    let attention: Attention?
    var working = false

    var body: some View {
        if attention == .waiting {
            Circle().fill(Self.waiting).frame(width: 8, height: 8)
                .help("Waiting for you")
        } else if working {
            ProgressView()
                .controlSize(.mini)
        } else if attention == .unread {
            Circle().fill(Self.unread).frame(width: 8, height: 8)
                .help("Unread")
        }
    }
}

struct GitGlyph: Shape {
    let merged: Bool

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 8) * unit, y: rect.midY + (y - 8) * unit)
        }
        var path = Path()
        func ring(_ x: CGFloat, _ y: CGFloat) {
            let center = point(x, y)
            path.addEllipse(in: CGRect(x: center.x - 1.8 * unit, y: center.y - 1.8 * unit, width: 3.6 * unit, height: 3.6 * unit))
        }
        ring(4, 3.5)
        path.move(to: point(4, 5.3))
        if merged {
            path.addLine(to: point(4, 14.5))
            ring(12, 10)
            path.move(to: point(4, 6.5))
            path.addQuadCurve(to: point(10.2, 10), control: point(4.5, 10))
        } else {
            path.addLine(to: point(4, 10.7))
            ring(4, 12.5)
            ring(12, 12.5)
            path.move(to: point(12, 10.7))
            path.addLine(to: point(12, 5.5))
            path.addQuadCurve(to: point(10, 3.5), control: point(12, 3.5))
            path.addLine(to: point(8.5, 3.5))
            path.move(to: point(10, 1.8))
            path.addLine(to: point(8.3, 3.5))
            path.addLine(to: point(10, 5.2))
        }
        return path
    }
}

struct PullRequestIcon: View {
    let badge: PullRequestBadge

    var body: some View {
        HStack(spacing: 3) {
            GitGlyph(merged: badge.state == .merged)
                .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13)
            if badge.count > 1 {
                Text(badge.count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .help(help)
    }

    private var color: Color {
        switch badge.state {
        case .open: Color(red: 0.29, green: 0.61, blue: 0.30)
        case .merged: Color(red: 0.57, green: 0.48, blue: 0.85)
        case .closed: Color(red: 0.82, green: 0.29, blue: 0.27)
        }
    }

    private var help: String {
        guard badge.count == 1 else { return String(localized: "\(badge.count) pull requests") }
        return switch badge.state {
        case .open: String(localized: "Open pull request")
        case .merged: String(localized: "Merged pull request")
        case .closed: String(localized: "Closed pull request")
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .lineLimit(1)
            Text(verbatim: "\(session.workingDirectory.lastPathComponent) · \(session.accountName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct RecentRow: View {
    let past: PastSession
    var showsRepository = true

    private var place: String? {
        showsRepository ? past.repositoryName : past.worktreeName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: past.title)
                .lineLimit(1)
            HStack(spacing: 4) {
                if let place {
                    Text(verbatim: place)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(verbatim: "·")
                }
                Text(past.lastActivity, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help(Text(verbatim: "\(past.title)\n\(past.directory.path)"))
    }
}

struct AllSessionsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [(name: String, sessions: [PastSession])] {
        let matching = model.recentNotOpen.filter { past in
            query.isEmpty
                || past.title.localizedCaseInsensitiveContains(query)
                || past.projectName.localizedCaseInsensitiveContains(query)
        }
        let grouped = Dictionary(grouping: matching, by: \.repositoryName)
        return grouped
            .map { (name: $0.key, sessions: $0.value) }
            .sorted { ($0.sessions.first?.lastActivity ?? .distantPast) > ($1.sessions.first?.lastActivity ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(group.sessions) { past in
                            Button {
                                model.open(past)
                                dismiss()
                            } label: {
                                HStack(spacing: 6) {
                                    RecentRow(past: past, showsRepository: false)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let pullRequests = model.pullRequests(of: past) {
                                        PullRequestIcon(badge: pullRequests)
                                    }
                                    StatusDot(attention: model.attention(of: past))
                                        .frame(width: 18)
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(verbatim: "\(group.name) (\(group.sessions.count))")
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search sessions"))
            .navigationTitle("All Sessions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
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
