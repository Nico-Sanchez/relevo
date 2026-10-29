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
        .onAppear { Task { await model.refresh() } }
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
            Text("Cuentas de Claude")
                .font(.headline)

            if let notice = model.notice {
                Notice(text: notice) { model.notice = nil }
            }

            SectionTitle(text: "Cuenta actual")
            if let current = model.snapshot.current {
                if renaming {
                    HStack {
                        TextField("Nombre de la cuenta", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveName(for: current) }
                        Button("Guardar") { saveName(for: current) }
                    }
                } else {
                    AccountRow(account: current, isCurrent: true) {
                        newName = current.name
                        renaming = true
                    }
                }
            } else {
                Text("Claude no tiene ninguna cuenta abierta.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            if !model.snapshot.others.isEmpty {
                SectionTitle(text: "Cambiar a")
                ForEach(model.snapshot.others) { account in
                    Button { model.screen = .switching(account) } label: {
                        AccountRow(account: account, isCurrent: false)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }

            Divider()
            MenuRow(title: "Agregar cuenta…", systemImage: "person.badge.plus") { model.screen = .adding }
            MenuRow(title: "Traer sesiones a esta cuenta…", systemImage: "tray.and.arrow.down") { model.screen = .bringing }
                .disabled(model.snapshot.current?.location == nil)
            Divider()
            Toggle("Abrir al iniciar sesión", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 8)
            MenuRow(title: "Salir", systemImage: "power") { NSApp.terminate(nil) }
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
            BackHeader(title: "Agregar cuenta") { model.screen = .home }
            Text("Claude se cierra y se abre sin sesión para que entres con la otra cuenta. La actual queda guardada y volvés a ella con un clic.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Email de la cuenta", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Label("No uses «Cerrar sesión» de Claude en una cuenta guardada: invalida el login que guardé.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Continuar", action: submit)
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
