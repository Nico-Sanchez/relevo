import ClaudeAccountsCore
import SwiftUI

struct SessionPicker: View {
    @Bindable var model: AppModel
    let destination: Account
    let switching: Bool
    @State private var groups: [SessionGroup]?
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BackHeader(title: switching ? "Cambiar a \(destination.name)" : "Traer sesiones") { model.screen = .home }
            Text(switching ? "Claude se cierra y se vuelve a abrir con esta cuenta." : "Claude se cierra y se vuelve a abrir.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if destination.location == nil {
                Text("Todavía no sé en qué organización está esta cuenta. Vas a poder traer sesiones después de entrar.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let groups {
                if groups.isEmpty {
                    Text("No hay sesiones abiertas en otras cuentas.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("¿Qué sesiones abiertas llevo a \(destination.name)?")
                        .font(.callout)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(groups) { group in
                                groupSection(group)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button(primaryTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!switching && selected.isEmpty)
            }
        }
        .task {
            guard let target = destination.location else { return }
            let loaded = await model.sessionGroups(excluding: target)
            let leaving = model.snapshot.current?.location
            let preselected = loaded.filter { !switching || $0.location == leaving }
            groups = loaded
            selected = Set(preselected.flatMap { group in group.sessions.map { key(group, $0) } })
            expanded = Set(preselected.map(\.id))
        }
    }

    private var primaryTitle: String {
        switch (switching, selected.count) {
        case (true, 0): "Cambiar"
        case (true, let count): "Cambiar y llevar \(count)"
        case (false, let count): "Traer \(count)"
        }
    }

    private func groupSection(_ group: SessionGroup) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(group.id) },
            set: { open in
                if open {
                    expanded.insert(group.id)
                } else {
                    expanded.remove(group.id)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.sessions) { session in
                    Toggle(isOn: Binding(
                        get: { selected.contains(key(group, session)) },
                        set: { include in
                            if include {
                                selected.insert(key(group, session))
                            } else {
                                selected.remove(key(group, session))
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .lineLimit(1)
                            Text(session.lastActivity, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.leading, 18)
        } label: {
            Toggle(isOn: Binding(
                get: { group.sessions.allSatisfy { selected.contains(key(group, $0)) } },
                set: { include in
                    for session in group.sessions {
                        if include {
                            selected.insert(key(group, session))
                        } else {
                            selected.remove(key(group, session))
                        }
                    }
                }
            )) {
                Text("\(group.name) (\(group.sessions.count))")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func key(_ group: SessionGroup, _ session: SessionSummary) -> String {
        "\(group.id)/\(session.id)"
    }

    private func confirm() {
        let sessions = (groups ?? []).flatMap { group in group.sessions.filter { selected.contains(key(group, $0)) } }
        Task {
            if switching {
                await model.switchTo(destination, bringing: sessions)
            } else if let target = destination.location {
                await model.bring(sessions, to: target)
            }
        }
    }
}
