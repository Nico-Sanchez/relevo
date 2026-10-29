import ClaudeAccountsCore
import SwiftUI

struct AccountRow: View {
    let account: Account
    let isCurrent: Bool
    var rename: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: account.name, seed: account.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(account.orgName ?? "Organización desconocida")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let rename {
                Button(action: rename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Cambiar el nombre")
            }
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isCurrent ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
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
                Text(String(name.first(where: \.isLetter) ?? "?").uppercased())
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

struct MenuRow: View {
    let title: String
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
    let text: String

    var body: some View {
        Text(text.uppercased())
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
