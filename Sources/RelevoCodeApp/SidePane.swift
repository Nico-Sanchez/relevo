import RelevoCI
import RelevoCode
import SwiftUI

enum SidePaneTab: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case pullRequest = "Pull Request"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: String(localized: "Changes")
        case .pullRequest: String(localized: "Pull Request")
        }
    }
}

struct SidePane: View {
    let session: Session
    let monitor: PullRequestMonitor?
    let environment: [String: String]
    @AppStorage("sidePaneTab") private var tab = SidePaneTab.changes

    var body: some View {
        VStack(spacing: 0) {
            Picker("Pane", selection: $tab) {
                ForEach(SidePaneTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .changes:
                ChangesView(session: session, environment: environment)
            case .pullRequest:
                if let monitor {
                    PullRequestView(monitor: monitor)
                } else {
                    ContentUnavailableView("Not watching", systemImage: "arrow.triangle.pull")
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct ChangesView: View {
    let session: Session
    let environment: [String: String]
    @AppStorage("diffScope") private var scope = DiffScope.uncommitted
    @State private var result: DiffResult?
    @State private var problem: String?

    private var refreshKey: String {
        "\(scope.rawValue)|\(session.workingDirectory.path)|\(session.items.count)|\(session.isBusy)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Scope", selection: $scope) {
                    Text("Uncommitted").tag(DiffScope.uncommitted)
                    Text("Branch").tag(DiffScope.branch)
                }
                .labelsHidden()
                .fixedSize()
                if let result {
                    Text(summary(result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if let problem {
                ContentUnavailableView("No changes to show", systemImage: "exclamationmark.triangle", description: Text(problem))
                    .frame(maxHeight: .infinity)
            } else if let result, result.files.isEmpty {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle", description: Text(scope == .branch ? String(localized: "This branch matches \(result.base ?? String(localized: "its base")).") : String(localized: "The working tree is clean.")))
            } else if let result {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(result.files) { file in
                            FileDiffView(file: file)
                        }
                    }
                    .padding(10)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: refreshKey) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        let directory = session.workingDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            result = nil
            problem = String(localized: "This session's folder doesn't exist anymore.")
            return
        }
        guard GitDiff.isRepository(directory) else {
            result = nil
            problem = String(localized: "This folder isn't a git repository.")
            return
        }
        let scope = scope
        let environment = environment
        let loaded = await Task.detached { Result { try GitDiff.load(in: directory, scope: scope, environment: environment) } }.value
        switch loaded {
        case .success(let value):
            result = value
            problem = nil
        case .failure(let error):
            problem = String(describing: error).split(separator: "\n").first.map(String.init) ?? String(describing: error)
        }
    }

    private func summary(_ result: DiffResult) -> String {
        let additions = result.files.reduce(0) { $0 + $1.additions }
        let deletions = result.files.reduce(0) { $0 + $1.deletions }
        return String(localized: "\(result.files.count) files") + "  +\(additions) −\(deletions)"
    }
}

struct FileDiffView: View {
    let file: DiffFile
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Text(Self.badge(file.change))
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(Self.color(file.change))
                    Text(verbatim: file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    if file.additions > 0 {
                        Text(verbatim: "+\(file.additions)").foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text(verbatim: "−\(file.deletions)").foregroundStyle(.red)
                    }
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider()
                if file.isBinary {
                    Text("Binary file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else if file.hunks.isEmpty {
                    Text(file.change == .renamed ? String(localized: "Renamed without changes") : String(localized: "No content changes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    DiffView(lines: file.hunks.flatMap { ["@@ -\($0.oldStart) +\($0.newStart) @@"] + $0.lines }, maxHeight: 600)
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    static func badge(_ change: DiffFile.Change) -> String {
        switch change {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    static func color(_ change: DiffFile.Change) -> Color {
        switch change {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        }
    }
}

struct PullRequestView: View {
    let monitor: PullRequestMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch monitor.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                case .loaded(nil):
                    Label("This branch has no pull request.", systemImage: "arrow.triangle.pull")
                        .foregroundStyle(.secondary)
                case .loaded(let pullRequest?):
                    header(pullRequest)
                    autofix
                    checks(pullRequest)
                    feedback(pullRequest)
                }
                HStack {
                    if let checked = monitor.lastChecked {
                        Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await monitor.refresh() }
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private func header(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = URL(string: pullRequest.url) {
                Link(destination: url) {
                    Text(verbatim: "#\(pullRequest.number) \(pullRequest.title)")
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                }
            }
            HStack(spacing: 6) {
                Text(Self.stateName(pullRequest.state))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(pullRequest.isOpen ? Color.green.opacity(0.2) : Color.secondary.opacity(0.2), in: Capsule())
                Text(verbatim: "\(pullRequest.headRef) → \(pullRequest.baseRef)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if pullRequest.hasConflicts {
                    Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var autofix: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { monitor.autofix }, set: { value in Task { await monitor.setAutofix(value) } })) {
                Label("Auto-fix", systemImage: "bolt.fill")
            }
            .toggleStyle(.switch)
            Text("When CI fails, a collaborator leaves feedback or the branch conflicts, this session gets a message to fix it, commit and push.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !monitor.queued.isEmpty {
                Text("\(monitor.queued.count) waiting until the session is free")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func checks(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checks").font(.subheadline.weight(.semibold))
            if pullRequest.checks.isEmpty {
                Text("None reported.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(pullRequest.checks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 6) {
                    Self.icon(check.outcome)
                    if let link = check.link, let url = URL(string: link) {
                        Link(check.name, destination: url)
                    } else {
                        Text(check.name)
                    }
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    private func feedback(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review feedback").font(.subheadline.weight(.semibold))
            if pullRequest.feedback.isEmpty {
                Text("None.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pullRequest.feedback, id: \.id) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(verbatim: "@\(item.author)").fontWeight(.medium)
                        if !item.isFromCollaborator {
                            Text("not a collaborator").font(.caption2).foregroundStyle(.orange)
                        }
                        if let location = item.location {
                            Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    Text(item.body)
                        .font(.callout)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    static func stateName(_ state: String) -> String {
        switch state {
        case "OPEN": String(localized: "pr.state.open", defaultValue: "Open")
        case "MERGED": String(localized: "pr.state.merged", defaultValue: "Merged")
        case "CLOSED": String(localized: "pr.state.closed", defaultValue: "Closed")
        default: state.capitalized
        }
    }

    @ViewBuilder
    static func icon(_ outcome: Check.Outcome) -> some View {
        switch outcome {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "clock").foregroundStyle(.orange)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
