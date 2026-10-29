import ClaudeAccountsCore
import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let progress = model.progress {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                switch model.screen {
                case .home:
                    HomeView(model: model)
                case .switching(let account):
                    SessionPicker(model: model, destination: account, switching: true)
                case .bringing:
                    if let current = model.snapshot.current {
                        SessionPicker(model: model, destination: current, switching: false)
                    }
                case .adding:
                    AddAccountView(model: model)
                }
            }
        }
        .padding(12)
        .onAppear {
            Task {
                await model.refresh()
                await model.refreshUsage()
            }
        }
        .onDisappear {
            if model.progress == nil {
                model.screen = .home
            }
        }
    }
}

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Accounts")
                .font(.headline)

            if let notice = model.notice {
                Notice(text: notice) { model.notice = nil }
            }

            SectionTitle(title: "Current account")
            if let current = model.snapshot.current {
                if renaming {
                    HStack {
                        TextField("Account name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveName(for: current) }
                        Button("Save") { saveName(for: current) }
                    }
                } else {
                    AccountRow(account: current, isCurrent: true, usage: model.usage[current.id]) {
                        newName = current.name ?? ""
                        renaming = true
                    }
                }
            } else {
                Text("Claude has no account signed in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            if !model.snapshot.others.isEmpty {
                SectionTitle(title: "Switch to")
                ForEach(model.snapshot.others) { account in
                    Button { model.screen = .switching(account) } label: {
                        AccountRow(account: account, isCurrent: false, usage: model.usage[account.id])
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }

            usageFooter

            Divider()
            MenuRow(title: "Add account…", systemImage: "person.badge.plus") { model.screen = .adding }
            MenuRow(title: "Bring sessions to this account…", systemImage: "tray.and.arrow.down") { model.screen = .bringing }
                .disabled(model.snapshot.current?.location == nil)
            Divider()
            Toggle("Open at login", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 8)
            MenuRow(title: "Quit", systemImage: "power") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder
    private var usageFooter: some View {
        if model.needsKeychainAccess {
            HStack(alignment: .top) {
                Text("Allow access to the “Claude Safe Storage” keychain item to see each account's usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.refreshUsage(force: true) } }
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
        } else if let updatedAt = model.usageUpdatedAt {
            HStack {
                Text("Usage updated \(updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refreshUsage(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(Text("Refresh usage"))
            }
            .padding(.horizontal, 8)
        }
    }

    private func saveName(for account: Account) {
        renaming = false
        Task { await model.rename(account, to: newName) }
    }
}

struct AddAccountView: View {
    @Bindable var model: AppModel
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BackHeader(title: String(localized: "Add account")) { model.screen = .home }
            Text("Claude quits and opens signed out so you can sign in with the other account. The current one stays saved, and you can come back to it with one click.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Account email", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Label("Don't use Claude's “Log out” on a saved account: it invalidates the saved login.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        let name = trimmedName
        Task { await model.addAccount(named: name) }
    }
}
