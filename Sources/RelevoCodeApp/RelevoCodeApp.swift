import AppKit
import RelevoCode
import SwiftUI

@main
struct RelevoCodeApp: App {
    @State private var model = AppModel(notifier: SystemNotifier())

    var body: some Scene {
        WindowGroup("Relevo Code", id: WindowRoot.id, for: String.self) { $accountID in
            WindowRoot(model: model, accountID: $accountID)
        }
        .windowResizability(.contentMinSize)
        .commands {
            WindowCommands(model: model)
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
    var accounts: [ClaudeAccount]
    var accountInfo: [String: AccountInfo] = [:]
    var recent: [PastSession] = []
    var desktop: [String: DesktopSession] = [:]
    var environment: [String: String]?
    var executable: URL?
    var problem: String?
    var monitors: [Session.ID: PullRequestMonitor] = [:]
    var seen: [String: Date]
    var owners: [String: String] = [:]
    var focusRequest: FocusRequest?
    private(set) var seenOpen: [Session.ID: Date] = [:]
    private(set) var assigned: [String: String]
    private(set) var themes: [String: AccountTheme]
    private(set) var windowAccounts: [UUID: String] = [:]
    private(set) var viewing: [UUID: Session.ID] = [:]
    @ObservationIgnored var openWindow: ((String) -> Void)?
    @ObservationIgnored var isActive: () -> Bool = { NSApp?.isActive ?? false }
    @ObservationIgnored var activate: () -> Void = { NSApp?.activate() }

    let notifier: any Notifier
    private let defaults: UserDefaults
    private var loading: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, notifier: any Notifier = SilentNotifier()) {
        self.defaults = defaults
        self.notifier = notifier
        accounts = [.standard] + (defaults.stringArray(forKey: "accountFolders") ?? []).map {
            ClaudeAccount(configDirectory: URL(filePath: $0))
        }
        seen = ((defaults.dictionary(forKey: "seenSessions") as? [String: Double]) ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
        assigned = (defaults.dictionary(forKey: "sessionAccounts") as? [String: String]) ?? [:]
        themes = ((defaults.dictionary(forKey: "accountThemes") as? [String: String]) ?? [:]).compactMapValues(AccountTheme.init)
        notifier.onOpen = { [weak self] in self?.reveal($0) }
    }

    var waitingCount: Int {
        sessions.filter { $0.status == .waitingForPermission }.count
    }

    func reveal(_ id: Session.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let account = owner(of: session)
        focusRequest = FocusRequest(accountID: account.id, session: id)
        if !windowAccounts.values.contains(account.id) {
            openWindow?(account.id)
        }
        activate()
    }

    func notice(_ moment: Session.Moment, from session: Session) {
        guard !isActive() || !viewing.values.contains(session.id) else { return }
        notifier.post(Banner(
            session: session.id, title: session.title, subtitle: name(of: owner(of: session)),
            body: Self.describe(moment), sound: { if case .needsYou = moment { true } else { false } }()
        ))
    }

    static func describe(_ moment: Session.Moment) -> String {
        switch moment {
        case .needsYou(let request):
            if let question = request.questions?.first {
                return question.question
            }
            let detail = request.description ?? request.detail.split(separator: "\n").first.map(String.init) ?? ""
            let action = String(localized: "Wants to use \(request.displayName)")
            return detail.isEmpty ? action : "\(action): \(detail.prefix(160))"
        case .finished(let reply):
            let line = reply?.split(separator: "\n").first.map { String($0.prefix(200)) }
            return line ?? String(localized: "Finished its turn")
        case .stopped(let message):
            guard let message, !message.isEmpty else { return String(localized: "Stopped") }
            return String(localized: "Stopped: \(String(message.prefix(160)))")
        }
    }

    var isEmpty: Bool {
        executable != nil && sessions.isEmpty && recent.isEmpty
    }

    func sessions(of account: ClaudeAccount) -> [Session] {
        sessions.filter { owner(of: $0) == account }
    }

    func recent(of account: ClaudeAccount) -> [PastSession] {
        let open = Set(sessions.compactMap(\.sessionID))
        return recent.filter { !open.contains($0.id) && owner(of: $0) == account.id }
    }

    func owner(of session: Session) -> ClaudeAccount {
        account(named: session.configuration.configDirectory)
    }

    func owner(of past: PastSession) -> String? {
        owners[past.id] ?? assigned[past.id] ?? accounts.first?.id
    }

    var lastFolder: URL? {
        get { defaults.string(forKey: "lastFolder").map { URL(filePath: $0) } }
        set { defaults.set(newValue?.path, forKey: "lastFolder") }
    }

    var lastPermissionMode: String {
        get { defaults.string(forKey: "lastPermissionMode") ?? "default" }
        set { defaults.set(newValue, forKey: "lastPermissionMode") }
    }

    func load() async {
        if let loading {
            return await loading.value
        }
        let task = Task { await performLoad() }
        loading = task
        await task.value
    }

    private func performLoad() async {
        let environment = await Task.detached { ShellEnvironment.load() }.value
        self.environment = environment
        executable = ShellEnvironment.claudeExecutable(in: environment)
        if executable == nil {
            problem = String(localized: "Claude Code isn't installed, or it isn't on your shell's PATH.")
            return
        }
        notifier.authorize()
        await refreshAccounts()
        await refreshRecent()
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
        let (accounts, assigned) = (accounts, assigned)
        let (recent, desktop, owners) = await Task.detached {
            let desktop = SessionLibrary.desktopSessions()
            let recent = SessionLibrary.relevant(SessionLibrary.recent(in: directories, limit: 300), desktop: desktop)
            return (recent, desktop, SessionOwners.resolve(recent.map(\.id), accounts: accounts, assigned: assigned, desktop: desktop))
        }.value
        self.recent = recent
        self.desktop = desktop
        self.owners = owners.merging(self.assigned) { $1 }
    }

    func name(of account: ClaudeAccount) -> String {
        accountInfo[account.id]?.email ?? account.folderName
    }

    func detail(of account: ClaudeAccount) -> String {
        guard let info = accountInfo[account.id] else { return account.folderName }
        return [info.organization, info.subscription?.capitalized].compactMap { $0 }.joined(separator: " · ")
    }

    func theme(of account: ClaudeAccount) -> AccountTheme {
        if let theme = themes[account.id] {
            return theme
        }
        let index = accounts.firstIndex(of: account) ?? 0
        return AccountTheme.allCases[index % AccountTheme.allCases.count]
    }

    func setTheme(_ theme: AccountTheme, for account: ClaudeAccount) {
        themes[account.id] = theme
        defaults.set(themes.mapValues(\.rawValue), forKey: "accountThemes")
    }

    func attach(_ window: UUID, account: ClaudeAccount, viewing session: Session.ID?) {
        windowAccounts[window] = account.id
        viewing[window] = session
        if let session {
            notifier.withdraw(session)
        }
    }

    func detach(_ window: UUID) {
        windowAccounts[window] = nil
        viewing[window] = nil
    }

    func hasWindow(for account: ClaudeAccount, besides window: UUID) -> Bool {
        windowAccounts.contains { $0.key != window && $0.value == account.id }
    }

    var accountForNewWindow: ClaudeAccount {
        let shown = Set(windowAccounts.values)
        return accounts.first { !shown.contains($0.id) } ?? accounts.first ?? .standard
    }

    func attention(of account: ClaudeAccount) -> Attention? {
        strongest(sessions(of: account).compactMap(attention(of:)) + recent(of: account).compactMap(attention(of:)))
    }

    func attention(otherThan account: ClaudeAccount) -> Attention? {
        strongest(accounts.filter { $0 != account }.compactMap(attention(of:)))
    }

    private func strongest(_ marks: [Attention]) -> Attention? {
        marks.contains(.waiting) ? .waiting : marks.first
    }

    func otherAccounts(than account: ClaudeAccount) -> [ClaudeAccount] {
        accounts.filter { $0 != account }
    }

    func canHandOff(_ session: Session) -> Bool {
        accounts.count > 1 && (session.status == .dormant || (session.sessionID != nil && !session.isBusy))
    }

    func handOff(_ session: Session, to account: ClaudeAccount) -> Session? {
        guard account != owner(of: session), canHandOff(session), let id = session.sessionID else { return nil }
        let moved: Session
        if session.status == .dormant {
            session.setAccount(configDirectory: account.configDirectory, name: name(of: account))
            moved = session
        } else {
            guard let continuation = session.continuation(
                configDirectory: account.configDirectory, accountName: name(of: account), fork: isOpenInDesktop(id)
            ) else { return nil }
            close(session)
            show(continuation)
            moved = continuation
        }
        if !moved.configuration.fork {
            assign(id, to: account)
        }
        return moved
    }

    func handOff(_ past: PastSession, to account: ClaudeAccount) -> Session {
        if !isOpenInDesktop(past.id) {
            assign(past.id, to: account)
        }
        return open(past, in: account)
    }

    private func assign(_ sessionID: String, to account: ClaudeAccount) {
        assigned[sessionID] = account.id
        owners[sessionID] = account.id
        defaults.set(assigned, forKey: "sessionAccounts")
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

    func startSession(in folder: URL, account: ClaudeAccount, permissionMode: String, worktree: Bool) -> Session {
        let configuration = SessionConfiguration(
            directory: folder, configDirectory: account.configDirectory, permissionMode: permissionMode,
            worktree: worktree ? "session-\(UUID().uuidString.prefix(6).lowercased())" : nil
        )
        let session = Session(configuration: configuration, accountName: name(of: account), environment: environment ?? [:], executable: executable)
        show(session)
        lastFolder = folder
        lastPermissionMode = permissionMode
        session.start()
        return session
    }

    func open(_ past: PastSession, in account: ClaudeAccount) -> Session {
        if let existing = sessions.first(where: { $0.sessionID == past.id }) {
            return existing
        }
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
        return session
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
        guard !viewing.values.contains(session.id), let ended = session.lastTurnEnded else { return nil }
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
        if session.status != .dormant, let id = session.sessionID {
            assign(id, to: owner(of: session))
        }
        sessions.removeAll { $0.id == session.id }
    }

    func observe(_ session: Session) {
        session.onMoment = { [weak self, weak session] moment in
            guard let self, let session else { return }
            self.notice(moment, from: session)
        }
    }

    private func show(_ session: Session) {
        observe(session)
        sessions.insert(session, at: 0)
        let monitor = PullRequestMonitor(session: session, environment: environment ?? [:])
        monitors[session.id] = monitor
        monitor.start()
    }
}

struct ContentView: View {
    let model: AppModel
    @Bindable var window: WindowModel
    @State private var titlebarHeight: CGFloat = 0

    var body: some View {
        let theme = model.theme(of: window.account)
        NavigationSplitView {
            SidebarView(model: model, window: window)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            detail
        }
        .overlay(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .overlay(theme.color.opacity(0.35))
                .frame(height: titlebarHeight)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .background { WindowProbe(titlebarHeight: $titlebarHeight) { window.nsWindow = $0 } }
        .tint(theme.color)
        .sheet(isPresented: $window.showingNewSession) {
            NewSessionView(model: model, window: window)
        }
        .onChange(of: window.selection) { previous, current in
            model.markSeen(previous)
            model.markSeen(current)
            if case .recent(let id) = current, let past = model.recent.first(where: { $0.id == id }) {
                window.open(past)
            }
            window.attach()
        }
        .onChange(of: model.sessions.map(\.id)) {
            window.reconcile()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshRecent() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = window.selected {
            SessionView(session: session, model: model, window: window)
                .id(session.id)
        } else if let problem = model.problem {
            ContentUnavailableView("Can't start Claude Code", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else {
            ContentUnavailableView {
                Label("No session", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Start a new session, or pick a recent one to continue it.")
            } actions: {
                Button("New Session") { window.showingNewSession = true }
                    .disabled(model.executable == nil)
            }
        }
    }
}

struct WindowProbe: NSViewRepresentable {
    @Binding var titlebarHeight: CGFloat
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        WindowProbeView()
    }

    func updateNSView(_ probe: WindowProbeView, context: Context) {
        probe.found = found
        probe.report = { value in
            if titlebarHeight != value {
                titlebarHeight = value
            }
        }
    }
}

final class WindowProbeView: NSView {
    var found: (NSWindow) -> Void = { _ in }
    var report: (CGFloat) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.titlebarAppearsTransparent = true
        measure()
    }

    override func layout() {
        super.layout()
        measure()
    }

    private func measure() {
        guard let window, let content = window.contentView else { return }
        found(window)
        let height = max(0, content.frame.height - window.contentLayoutRect.height)
        Task { @MainActor [weak self] in self?.report(height) }
    }
}

struct SidebarView: View {
    static let recentLimit = 8

    let model: AppModel
    @Bindable var window: WindowModel
    @AppStorage("recentExpanded") private var recentExpanded = true
    @State private var showingAllSessions = false

    var body: some View {
        List(selection: $window.selection) {
            if !window.visibleSessions.isEmpty {
                Section("Open") {
                    ForEach(window.visibleSessions) { session in
                        SidebarRow(
                            pullRequests: model.pullRequests(of: session),
                            attention: model.attention(of: session),
                            working: session.status == .working || session.status == .starting,
                            background: !session.backgroundTasks.isEmpty
                        ) {
                            SessionRow(session: session)
                        } actions: {
                            OpenSessionMenu(model: model, window: window, session: session)
                        }
                        .tag(SidebarItem.open(session.id))
                    }
                }
            }
            Section("Recent", isExpanded: $recentExpanded) {
                let recent = window.visibleRecent
                ForEach(recent.prefix(Self.recentLimit)) { past in
                    SidebarRow(pullRequests: model.pullRequests(of: past), attention: model.attention(of: past)) {
                        RecentRow(past: past)
                    } actions: {
                        RecentSessionMenu(model: model, window: window, past: past)
                    }
                    .tag(SidebarItem.recent(past.id))
                }
                if recent.isEmpty {
                    Text("No conversations in this account yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if recent.count > Self.recentLimit {
                    Button {
                        showingAllSessions = true
                    } label: {
                        Text("See all \(recent.count)…")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AccountSwitcher(model: model, window: window)
        }
        .sheet(isPresented: $showingAllSessions) {
            AllSessionsView(model: model, window: window)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshRecent() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    window.showingNewSession = true
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .disabled(model.executable == nil)
            }
        }
    }
}

struct HandOffButtons: View {
    let model: AppModel
    let window: WindowModel
    let session: Session

    var body: some View {
        ForEach(model.otherAccounts(than: model.owner(of: session))) { account in
            Button(model.name(of: account)) { window.handOff(session, to: account) }
        }
    }
}

struct OpenSessionMenu: View {
    let model: AppModel
    let window: WindowModel
    let session: Session

    var body: some View {
        Menu("Continue in Another Account") {
            HandOffButtons(model: model, window: window, session: session)
        }
        .disabled(!model.canHandOff(session))
        Divider()
        Button("Close Session") { window.close(session) }
    }
}

struct RecentSessionMenu: View {
    let model: AppModel
    let window: WindowModel
    let past: PastSession

    var body: some View {
        Menu("Continue in Another Account") {
            ForEach(model.otherAccounts(than: window.account)) { account in
                Button(model.name(of: account)) { window.handOff(past, to: account) }
            }
        }
        .disabled(model.accounts.count < 2)
    }
}

struct AccountSwitcher: View {
    let model: AppModel
    let window: WindowModel
    @State private var choosing = false

    var body: some View {
        Button {
            choosing = true
        } label: {
            HStack(spacing: 8) {
                AccountLabel(model: model, account: window.account)
                StatusDot(attention: window.attentionElsewhere)
                    .help("Another account has a session that needs you")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(model.theme(of: window.account).color.opacity(0.14))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .popover(isPresented: $choosing, arrowEdge: .top) {
            AccountList(model: model, window: window) { choosing = false }
        }
        .help("Switch account")
    }
}

struct AccountList: View {
    let model: AppModel
    let window: WindowModel
    let done: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.accounts) { account in
                HStack(spacing: 4) {
                    Button {
                        window.switchAccount(to: account)
                        done()
                    } label: {
                        HStack(spacing: 8) {
                            AccountLabel(model: model, account: account)
                            StatusDot(attention: model.attention(of: account))
                                .frame(width: 10)
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .opacity(account == window.account ? 1 : 0)
                        }
                        .padding(.leading, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        done()
                        openWindow(id: WindowRoot.id, value: account.id)
                    } label: {
                        Image(systemName: "macwindow.badge.plus")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in a new window")
                }
            }
            Divider()
                .padding(.vertical, 4)
            ThemePicker(model: model, account: window.account)
                .padding(.horizontal, 8)
            Divider()
                .padding(.vertical, 4)
            Button {
                done()
                Task { @MainActor in
                    guard let folder = AccountFolderPanel.choose() else { return }
                    await model.addAccountFolder(folder)
                    window.switchAccount(to: ClaudeAccount(configDirectory: folder))
                }
            } label: {
                Label("Add Account…", systemImage: "plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 320)
    }
}

struct ThemePicker: View {
    let model: AppModel
    let account: ClaudeAccount

    var body: some View {
        HStack(spacing: 8) {
            Text("Color")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ForEach(AccountTheme.allCases) { theme in
                Button {
                    model.setTheme(theme, for: account)
                } label: {
                    Circle()
                        .fill(theme.color)
                        .frame(width: 16, height: 16)
                        .overlay {
                            if model.theme(of: account) == theme {
                                Circle().strokeBorder(.primary.opacity(0.7), lineWidth: 2).padding(-3)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.name)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AccountLabel: View {
    let model: AppModel
    let account: ClaudeAccount

    var body: some View {
        HStack(spacing: 8) {
            AccountAvatar(name: model.name(of: account), color: model.theme(of: account).color)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.name(of: account))
                    .lineLimit(1)
                Text(verbatim: model.detail(of: account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountAvatar: View {
    let name: String
    let color: Color

    var body: some View {
        Text(verbatim: name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color, in: Circle())
    }
}

enum AccountFolderPanel {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Choose a Claude Code config folder (the CLAUDE_CONFIG_DIR of a signed-in account).")
        panel.prompt = String(localized: "Add")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct SidebarRow<Content: View, Actions: View>: View {
    let pullRequests: PullRequestBadge?
    let attention: Attention?
    let working: Bool
    let background: Bool
    let content: Content
    let actions: Actions
    @State private var hovering = false

    init(
        pullRequests: PullRequestBadge?, attention: Attention?, working: Bool = false, background: Bool = false,
        @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions
    ) {
        self.pullRequests = pullRequests
        self.attention = attention
        self.working = working
        self.background = background
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
                    StatusDot(attention: attention, working: working, background: background)
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
    var background = false

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
        } else if background {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Something is still running in the background")
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
            Text(verbatim: session.workingDirectory.lastPathComponent)
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
    let window: WindowModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [(name: String, sessions: [PastSession])] {
        let matching = window.visibleRecent.filter { past in
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
                                window.open(past)
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
    let window: WindowModel
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
                    window.startSession(in: folder, account: account, permissionMode: permissionMode, worktree: worktree && isRepository)
                    dismiss()
                }
                .disabled(folder == nil)
            }
        }
        .onAppear {
            folder = model.lastFolder
            permissionMode = model.lastPermissionMode
            accountID = window.account.id
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
        guard let url = AccountFolderPanel.choose() else { return }
        Task {
            await model.addAccountFolder(url)
            accountID = ClaudeAccount(configDirectory: url).id
        }
    }
}
