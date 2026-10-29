import ClaudeAccountsCore
import SwiftUI

struct AccountRow: View {
    let account: Account
    let isCurrent: Bool
    let usage: UsageState?
    var rename: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: account.displayName, seed: account.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(account.displayOrg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                UsageMeters(state: usage)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if let rename {
                Button(action: rename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(Text("Rename"))
            }
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isCurrent ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

struct UsageMeters: View {
    static let mainWindows: Set<String> = ["five_hour", "seven_day"]

    let state: UsageState?

    var body: some View {
        switch state {
        case .loaded(let usage):
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(shown(usage)) { window in
                    GridRow {
                        Text(Display.windowName(window.id))
                            .foregroundStyle(.secondary)
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(color(for: window))
                                        .frame(width: proxy.size.width * min(max(window.utilization / 100, 0), 1))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        Text(verbatim: "\(Int(window.utilization.rounded()))%")
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                    .help(resetText(for: window))
                }
            }
            .font(.caption2)
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .failed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(message)
        case nil:
            EmptyView()
        }
    }

    private func shown(_ usage: Usage) -> [UsageWindow] {
        let main = usage.windows.filter { Self.mainWindows.contains($0.id) }
        let busiestOther = usage.windows
            .filter { !Self.mainWindows.contains($0.id) && $0.utilization > 0 }
            .max { $0.utilization < $1.utilization }
        return main + (busiestOther.map { [$0] } ?? [])
    }

    private func color(for window: UsageWindow) -> Color {
        switch window.utilization {
        case 90...: .red
        case 70...: .orange
        default: .green
        }
    }

    private func resetText(for window: UsageWindow) -> Text {
        guard let resetsAt = window.resetsAt else { return Text(verbatim: "") }
        return Text("Resets \(resetsAt.formatted(.relative(presentation: .named)))")
    }
}

struct Avatar: View {
    static let palette: [Color] = [.indigo, .teal, .orange, .pink, .purple, .blue, .mint, .brown]

    let name: String
    let seed: String

    var body: some View {
        let index = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.palette.count
        Circle()
            .fill(Self.palette[index].gradient)
            .frame(width: 30, height: 30)
            .overlay {
                Text(verbatim: String(name.first(where: \.isLetter) ?? "?").uppercased())
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

struct MenuRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }

    private struct Highlight: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(isEnabled && (hovering || configuration.isPressed) ? 0.08 : 0))
                )
                .onHover { hovering = $0 }
        }
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

struct BackHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct Notice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}
