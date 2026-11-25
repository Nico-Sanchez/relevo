import AppKit
import RelevoCode
import SwiftUI

struct SessionView: View {
    let session: Session
    let model: AppModel
    let window: WindowModel
    @State private var draft = ""
    @AppStorage("showingSidePane") private var showingSidePane = true
    @State private var isRepository = true

    var body: some View {
        VStack(spacing: 0) {
            Transcript(session: session)
            VStack(spacing: 8) {
                if let request = session.pendingPermissions.first {
                    if let questions = request.questions {
                        QuestionCard(request: request, questions: questions, session: session)
                            .id(request.id)
                    } else {
                        PermissionCard(request: request, session: session)
                    }
                }
                if session.status == .dormant {
                    ResumeBar(session: session, model: model, window: window)
                }
                if case .ended(let reason) = session.status {
                    EndedBanner(reason: reason)
                } else {
                    Composer(session: session, draft: $draft)
                }
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .inspector(isPresented: Binding(get: { showingSidePane && isRepository }, set: { showingSidePane = $0 })) {
            SidePane(session: session, monitor: model.monitors[session.id], environment: model.environment ?? [:])
                .inspectorColumnWidth(min: 280, ideal: 360, max: 640)
        }
        .task(id: session.workingDirectory) {
            let directory = session.workingDirectory
            isRepository = await Task.detached { GitDiff.isRepository(directory) }.value
        }
        .navigationTitle(session.title)
        .navigationSubtitle(session.workingDirectory.path)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    HandOffButtons(model: model, window: window, session: session)
                } label: {
                    Label("Continue in Another Account", systemImage: "arrow.triangle.branch")
                }
                .help("Move this conversation to another account")
                .disabled(!model.canHandOff(session))
                UsageView(windows: session.usage)
                Label(session.info?.account?.email ?? session.accountName, systemImage: "person.crop.circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                Button {
                    TerminalLauncher.open(session.workingDirectory)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .help("Open this session's folder in Ghostty")
                Button {
                    showingSidePane.toggle()
                } label: {
                    Label("Changes and Pull Request", systemImage: "sidebar.right")
                }
                .help(isRepository ? String(localized: "Show changes and the pull request") : String(localized: "This folder isn't a git repository."))
                .disabled(!isRepository)
                if session.cost > 0 {
                    Text(session.cost, format: .currency(code: "USD"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Cost of this session at API prices")
                }
            }
        }
    }
}

struct Transcript: View {
    let session: Session

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.items) { item in
                        ItemView(item: item, directory: session.workingDirectory, steering: session.steering.contains(item.id))
                            .id(item.id)
                    }
                    if session.status == .working || session.status == .starting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(session.activity ?? (session.status == .starting ? String(localized: "Starting Claude Code") : session.isThinking ? String(localized: "Thinking") : String(localized: "Working")))
                                .foregroundStyle(.secondary)
                        }
                        .id("activity")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.items) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: session.pendingPermissions) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

struct ItemView: View {
    let item: TranscriptItem
    let directory: URL
    var steering = false

    var body: some View {
        switch item.kind {
        case .user(let text):
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                if steering {
                    Label("Claude reads this at its next step", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .assistant(let text):
            MarkdownView(text: text)
        case .tool(let call):
            ToolCallView(call: call, directory: directory)
        case .automated(let summary, let text):
            AutomatedMessageView(summary: summary, text: text)
        case .notice(let notice):
            NoticeView(notice: notice)
        }
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let code):
                    ScrollView(.horizontal) {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                case .list(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: item.marker)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 14, alignment: .trailing)
                                Text(Self.inline(item.text))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, CGFloat(item.level) * 20)
                        }
                    }
                case .quote(let text):
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tertiary)
                            .frame(width: 3)
                        Text(Self.inline(text))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .table(let header, let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                                    Text(Self.inline(cell)).fontWeight(.semibold)
                                }
                            }
                            Divider()
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Text(Self.inline(cell))
                                    }
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct ToolCallView: View {
    let call: ToolCall
    let directory: URL
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.icon(for: call.name))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(call.name)
                        .fontWeight(.medium)
                    Text(call.summary(relativeTo: directory))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    ToolState(state: call.state)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                ToolDetail(call: call)
                    .padding(12)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    static func icon(for tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write": "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        case "AskUserQuestion": "questionmark.bubble"
        default: "wrench.and.screwdriver"
        }
    }
}

struct ToolState: View {
    let state: ToolCall.State

    var body: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .awaitingPermission:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark").foregroundStyle(.red)
        case .denied:
            Image(systemName: "nosign").foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

struct ToolDetail: View {
    let call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !call.patch.isEmpty {
                DiffView(lines: call.patch.flatMap { ["@@ -\($0.oldStart) +\($0.newStart) @@"] + $0.lines })
            } else if let added = call.addedText {
                DiffView(lines: added.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" })
            } else {
                CodeText(text: call.input.prettyText)
            }
            if let result = call.result, call.patch.isEmpty || call.state == .failed {
                CodeText(text: String(result.prefix(6000)))
                    .foregroundStyle(call.state == .failed ? .red : .secondary)
            }
        }
    }
}

struct CodeText: View {
    let text: String
    var maxHeight: CGFloat = 260

    var body: some View {
        Capped(maxHeight: maxHeight) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Capped<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        MaxHeightLayout(maxHeight: maxHeight) {
            ViewThatFits(in: .vertical) {
                content
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    content
                }
            }
        }
    }
}

struct MaxHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: maxHeight))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct DiffView: View {
    let lines: [String]
    var maxHeight: CGFloat = 320

    var body: some View {
        Capped(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(Self.color(for: line))
                }
            }
            .textSelection(.enabled)
        }
    }

    static func color(for line: String) -> Color {
        if line.hasPrefix("@@") { return .blue.opacity(0.12) }
        if line.hasPrefix("+") { return .green.opacity(0.15) }
        if line.hasPrefix("-") { return .red.opacity(0.15) }
        return .clear
    }
}

struct PermissionCard: View {
    let request: PermissionRequest
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Allow \(request.displayName)?")
                    .fontWeight(.semibold)
                if let description = request.description {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !request.detail.isEmpty {
                if request.toolName == "Edit" {
                    DiffView(lines: request.detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), maxHeight: 180)
                } else {
                    CodeText(text: String(request.detail.prefix(4000)), maxHeight: 160)
                }
            }
            HStack {
                Button("Deny", role: .cancel) { session.respond(request, .deny("The user denied this.")) }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if request.allowsEditsForSession {
                    Button("Allow edits this session") { session.respond(request, .allowEditsForSession) }
                }
                Button("Allow") { session.respond(request, .allow) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.4)))
    }
}

struct QuestionCard: View {
    static let color = Color(red: 0.26, green: 0.52, blue: 0.87)

    let request: PermissionRequest
    let questions: [Question]
    let session: Session
    @State private var chosen: [Int: Set<String>] = [:]
    @State private var writing: Set<Int> = []
    @State private var written: [Int: String] = [:]

    private var answers: [String: String]? {
        var answers: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            let other = writing.contains(index) ? written[index] : nil
            guard let answer = question.answer(choosing: chosen[index] ?? [], other: other) else { return nil }
            answers[question.question] = answer
        }
        return answers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Self.color)
                Text(questions.count == 1 ? String(localized: "Claude has a question") : String(localized: "Claude has \(questions.count) questions"))
                    .fontWeight(.semibold)
            }
            Capped(maxHeight: 360) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionView(question, at: index)
                    }
                }
            }
            HStack {
                Button("Skip", role: .cancel) { session.respond(request, .deny("The user chose not to answer.")) }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Answer") {
                    if let answers {
                        session.respond(request, .answer(answers))
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .tint(Self.color)
                .disabled(answers == nil)
            }
        }
        .padding(14)
        .background(Self.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Self.color.opacity(0.4)))
    }

    private func questionView(_ question: Question, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header = question.header {
                Text(verbatim: header.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: question.question)
                .fontWeight(.medium)
                .padding(.bottom, 2)
            ForEach(question.options, id: \.label) { option in
                OptionRow(
                    title: option.label, detail: option.description, multiple: question.multiSelect,
                    selected: chosen[index]?.contains(option.label) == true
                ) {
                    choose(option.label, for: question, at: index)
                }
            }
            OptionRow(title: String(localized: "Other"), detail: nil, multiple: question.multiSelect, selected: writing.contains(index)) {
                writeOther(for: question, at: index)
            }
            if writing.contains(index) {
                TextField("Your answer", text: Binding(get: { written[index] ?? "" }, set: { written[index] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 28)
            }
        }
    }

    private func choose(_ label: String, for question: Question, at index: Int) {
        if question.multiSelect {
            var labels = chosen[index] ?? []
            if labels.remove(label) == nil {
                labels.insert(label)
            }
            chosen[index] = labels
        } else {
            chosen[index] = [label]
            writing.remove(index)
        }
    }

    private func writeOther(for question: Question, at index: Int) {
        if question.multiSelect, writing.contains(index) {
            writing.remove(index)
        } else {
            writing.insert(index)
            if !question.multiSelect {
                chosen[index] = []
            }
        }
    }
}

struct OptionRow: View {
    let title: String
    let detail: String?
    let multiple: Bool
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch (multiple, selected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? QuestionCard.color : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? QuestionCard.color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Composer: View {
    let session: Session
    @Binding var draft: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 40, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        submit()
                        return .handled
                    }
            }
            HStack(spacing: 10) {
                SessionControls(session: session)
                Spacer()
                if session.isBusy {
                    Button {
                        session.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop")
                    .keyboardShortcut(".", modifiers: [.command])
                }
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .help("Send (Return)")
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .onAppear { focused = true }
    }

    private var placeholder: String {
        if session.status == .dormant {
            String(localized: "Send a message to continue this session…")
        } else if session.isBusy {
            String(localized: "Tell Claude something while it works…")
        } else {
            String(localized: "Ask Claude to do something…")
        }
    }

    private var canSend: Bool {
        session.acceptsMessages && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        session.send(draft)
        draft = ""
    }

    static func modeName(_ mode: String) -> String {
        NewSessionView.modes.first { $0.0 == mode }?.1 ?? mode
    }
}

struct NoticeView: View {
    let notice: Notice

    var body: some View {
        Label(Self.text(notice), systemImage: notice.isError ? "exclamationmark.triangle.fill" : "info.circle")
            .foregroundStyle(notice.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
    }

    static func text(_ notice: Notice) -> String {
        switch notice {
        case .compacted:
            return String(localized: "Earlier messages were summarized to free up context.")
        case .earlierHidden:
            return String(localized: "Earlier messages aren't shown.")
        case .turnFailed(let reason):
            return reason ?? String(localized: "The turn ended with an error.")
        case .refused(let setting, let reason):
            let reason = reason ?? String(localized: "Claude Code refused it.")
            switch setting {
            case .model: return String(localized: "Couldn't change the model: \(reason)")
            case .effort: return String(localized: "Couldn't change the effort: \(reason)")
            case .permissionMode: return String(localized: "Couldn't change the permission mode: \(reason)")
            }
        }
    }
}

struct EndedBanner: View {
    let reason: EndReason?

    private var text: String {
        switch reason {
        case nil: String(localized: "This session ended.")
        case .notInstalled: String(localized: "Claude Code isn't installed.")
        case .couldNotStart(let message): String(localized: "Claude Code couldn't start: \(message)")
        case .exited(let status, let message): message.isEmpty ? String(localized: "Claude Code exited with status \(Int(status)).") : message
        }
    }

    var body: some View {
        Label(text, systemImage: reason == nil ? "stop.circle" : "exclamationmark.triangle.fill")
            .foregroundStyle(reason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct UsageView: View {
    let windows: [UsageWindow]

    static func help(for window: UsageWindow) -> String {
        let used = Int(window.utilization)
        guard let reset = window.resetsAt else { return String(localized: "\(used)% used") }
        return String(localized: "\(used)% used, resets \(reset.formatted(.relative(presentation: .named)))")
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(windows.filter { ["five_hour", "seven_day"].contains($0.id) }) { window in
                HStack(spacing: 4) {
                    Text(window.id == "five_hour" ? String(localized: "5h") : String(localized: "Week"))
                        .foregroundStyle(.secondary)
                    Gauge(value: min(window.utilization, 100), in: 0...100) {}
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(window.utilization >= 80 ? .red : window.utilization >= 50 ? .orange : .green)
                        .frame(width: 44)
                }
                .font(.caption)
                .help(Self.help(for: window))
            }
        }
    }
}

struct ResumeBar: View {
    let session: Session
    let model: AppModel
    let window: WindowModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(explained: true)
            bar(explained: false)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func bar(explained: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.forward.circle")
                .foregroundStyle(.secondary)
                .help("Your next message continues it in")
            if explained {
                Text("Your next message continues it in")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Account", selection: Binding(
                    get: { model.account(named: session.configuration.configDirectory).id },
                    set: { id in
                        if let account = model.accounts.first(where: { $0.id == id }) {
                            window.handOff(session, to: account)
                        }
                    }
                )) {
                    ForEach(model.accounts) { account in
                        Text(model.name(of: account)).tag(account.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle("As a copy", isOn: Binding(get: { session.configuration.fork }, set: { session.setFork($0) }))
                .fixedSize()
                .help("Keeps the original untouched and continues in a new session. Use it when Claude Desktop or another account still has it open.")
            Spacer(minLength: 0)
            if model.isOpenInDesktop(session.configuration.resume) {
                Group {
                    if explained {
                        Label("Open in Desktop", systemImage: "desktopcomputer")
                    } else {
                        Image(systemName: "desktopcomputer")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Still open in Claude Desktop")
                .fixedSize()
            }
        }
    }
}

struct AutomatedMessageView: View {
    let summary: String
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").foregroundStyle(.orange)
                    Text(summary).fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                CodeText(text: text, maxHeight: 300)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.3)))
    }
}

struct SessionControls: View {
    let session: Session

    static let fallbackModels = [
        ModelOption(value: "default", displayName: "Default", description: nil, effortLevels: []),
        ModelOption(value: "opus", displayName: "Opus", description: nil, effortLevels: []),
        ModelOption(value: "sonnet", displayName: "Sonnet", description: nil, effortLevels: []),
        ModelOption(value: "haiku", displayName: "Haiku", description: nil, effortLevels: []),
    ]
    static let fallbackEfforts = ["low", "medium", "high", "xhigh", "max"]

    private var models: [ModelOption] {
        let known = session.info?.models ?? []
        return known.isEmpty ? Self.fallbackModels : known
    }

    private var currentModel: ModelOption? {
        models.first { $0.value == (session.selectedModel ?? "default") }
    }

    private var efforts: [String] {
        let levels = currentModel?.effortLevels ?? []
        return levels.isEmpty ? Self.fallbackEfforts : levels
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
        }
        .disabled({ if case .ended = session.status { true } else { false } }())
    }

    private var modelName: String {
        currentModel?.displayName ?? session.model ?? session.selectedModel ?? String(localized: "Default")
    }

    private var effortLabel: String {
        session.effort.map(SessionControls.effortName) ?? String(localized: "Default effort")
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(NewSessionView.modes, id: \.0) { mode in
                    Button {
                        session.setPermissionMode(mode.0)
                    } label: {
                        if mode.0 == session.permissionMode {
                            Label(mode.1, systemImage: "checkmark")
                        } else {
                            Text(mode.1)
                        }
                    }
                }
            } label: {
                if compact {
                    Image(systemName: Self.modeIcon(session.permissionMode))
                } else {
                    Text(Composer.modeName(session.permissionMode))
                }
            }
            .help(Composer.modeName(session.permissionMode))
            Menu {
                ForEach(models) { option in
                    Button {
                        session.setModel(option.value)
                    } label: {
                        if option.value == (session.selectedModel ?? "default") {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                if compact {
                    Image(systemName: "cpu")
                } else {
                    Text(modelName)
                }
            }
            .help(modelName)
            Menu {
                Button("Default") { session.setEffort(nil) }
                ForEach(efforts, id: \.self) { level in
                    Button {
                        session.setEffort(level)
                    } label: {
                        if level == session.effort {
                            Label(SessionControls.effortName(level), systemImage: "checkmark")
                        } else {
                            Text(SessionControls.effortName(level))
                        }
                    }
                }
            } label: {
                if compact {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                } else {
                    Text(effortLabel)
                }
            }
            .help(effortLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    static func modeIcon(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": "pencil"
        case "plan": "list.bullet.clipboard"
        case "bypassPermissions": "exclamationmark.shield"
        default: "hand.raised"
        }
    }

    static func effortName(_ level: String) -> String {
        switch level {
        case "low": String(localized: "Low effort")
        case "medium": String(localized: "Medium effort")
        case "high": String(localized: "High effort")
        case "xhigh": String(localized: "Extra high effort")
        case "max": String(localized: "Max effort")
        default: level
        }
    }
}

enum TerminalLauncher {
    static func open(_ directory: URL) {
        let workspace = NSWorkspace.shared
        guard let application = workspace.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        workspace.open([directory], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}
