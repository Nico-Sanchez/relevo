import AppKit
import RelevoCode
import SwiftUI

@MainActor
@Observable
final class SelectionWatcher {
    struct Selection: Equatable {
        let text: String
        let point: CGPoint
    }

    private(set) var selection: Selection?
    @ObservationIgnored var area: CGRect = .zero
    @ObservationIgnored private var window: () -> NSWindow? = { nil }
    @ObservationIgnored private var monitor: Any?

    func start(in window: @escaping () -> NSWindow?) {
        self.window = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        selection = nil
    }

    func clear() {
        selection = nil
    }

    static func selectedText(in window: NSWindow?) -> String? {
        guard let responder = window?.firstResponder as? NSView, !(responder is NSTextView) else { return nil }
        let text = responder.accessibilitySelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    func handle(_ event: NSEvent) {
        guard let window = window(), event.window === window else { return }
        guard event.type == .leftMouseUp else {
            selection = nil
            return
        }
        let location = event.locationInWindow
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.capture(at: location, in: window) }
        }
    }

    private func capture(at location: CGPoint, in window: NSWindow) {
        guard let content = window.contentView else { return }
        let local = content.convert(location, from: nil)
        let point = content.isFlipped ? local : CGPoint(x: local.x, y: content.bounds.height - local.y)
        guard area.contains(point), let text = Self.selectedText(in: window) else {
            selection = nil
            return
        }
        selection = Selection(text: text, point: point)
    }
}

struct QuoteButton: View {
    let watcher: SelectionWatcher
    let quote: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .onAppear { watcher.area = frame }
                    .onChange(of: frame) { _, current in watcher.area = current }
                if let selection = watcher.selection {
                    Button {
                        quote(selection.text)
                        watcher.clear()
                    } label: {
                        Label("Quote", systemImage: "text.quote")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .position(
                        x: min(max(selection.point.x - frame.minX, 50), max(frame.width - 50, 50)),
                        y: min(selection.point.y - frame.minY + 24, max(frame.height - 16, 16))
                    )
                    .help("Quote the selected text in your message")
                }
            }
        }
    }
}

struct QuotedText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Quote.parts(of: text).enumerated()), id: \.offset) { _, part in
                if part.quoted {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tertiary)
                            .frame(width: 3)
                        Text(part.text)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(part.text)
                }
            }
        }
    }
}
