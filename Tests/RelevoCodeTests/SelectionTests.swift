import AppKit
import SwiftUI
import Testing
@testable import RelevoCode
@testable import RelevoCodeApp

private let windowsAvailable = ProcessInfo.processInfo.environment["RELEVO_RENDER_DIR"] != nil

@MainActor
@Suite(.serialized, .enabled(if: windowsAvailable, "Set RELEVO_RENDER_DIR to run tests that need windows"))
struct SelectionTests {
    func window(with view: some View) async throws -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        return (window, hosting)
    }

    func select(in hosting: NSView, _ window: NSWindow) throws {
        let interaction = try #require(hosting.subviews.first { NSStringFromClass(type(of: $0)).contains("TextInteraction") })
        window.makeFirstResponder(interaction)
        interaction.perform(NSSelectorFromString("selectAll:"), with: nil)
    }

    @Test func readsTheSelectedTextButNotTheComposers() async throws {
        let (window, hosting) = try await window(with: Text("Ollama 0.40.18 runs as a service").textSelection(.enabled).padding())
        defer { window.close() }
        #expect(SelectionWatcher.selectedText(in: window) == nil)

        try select(in: hosting, window)
        #expect(SelectionWatcher.selectedText(in: window) == "Ollama 0.40.18 runs as a service")

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        editor.string = "my draft"
        hosting.addSubview(editor)
        window.makeFirstResponder(editor)
        editor.selectAll(nil)
        #expect(SelectionWatcher.selectedText(in: window) == nil)
    }

    @Test func offersAQuoteWhereTheMouseLetsGo() async throws {
        let (window, hosting) = try await window(with: Text("Ollama 0.40.18 runs as a service").textSelection(.enabled).padding())
        defer { window.close() }
        let watcher = SelectionWatcher()
        watcher.start { window }
        defer { watcher.stop() }
        watcher.area = CGRect(x: 0, y: 0, width: 420, height: 200)
        try select(in: hosting, window)

        let height = try #require(window.contentView?.bounds.height)
        let release = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 120, y: height - 20), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        watcher.handle(release)
        try await Task.sleep(for: .milliseconds(100))

        let selection = try #require(watcher.selection)
        #expect(selection.text == "Ollama 0.40.18 runs as a service")
        #expect(selection.point == CGPoint(x: 120, y: 20))

        let scroll = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        watcher.handle(scroll)
        #expect(watcher.selection == nil)

        watcher.area = CGRect(x: 200, y: 0, width: 50, height: 50)
        watcher.handle(release)
        try await Task.sleep(for: .milliseconds(100))
        #expect(watcher.selection == nil)
    }

    @Test func rendersTheQuoteButtonAndAQuotedMessage() async throws {
        let watcher = SelectionWatcher()
        let view = VStack(alignment: .leading, spacing: 14) {
            ItemView(item: TranscriptItem(id: "u1", kind: .user("> Ollama 0.40.18, con Homebrew.\n\n¿Por qué arranca solo al iniciar sesión?")), directory: URL(filePath: "/tmp"))
            MarkdownView(text: "Corre como servicio en segundo plano y arranca solo cuando iniciás sesión.")
        }
        .padding(20)
        .frame(width: 560, height: 220, alignment: .top)
        .overlay { QuoteButton(watcher: watcher, quote: { _ in }) }
        let (window, hosting) = try await window(with: view)
        defer { window.close() }
        watcher.start { window }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let interaction = try #require(hosting.subviews.last { NSStringFromClass(type(of: $0)).contains("TextInteraction") })
        window.makeFirstResponder(interaction)
        interaction.perform(NSSelectorFromString("selectAll:"), with: nil)
        let height = try #require(window.contentView?.bounds.height)
        let release = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 300, y: height - 150), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        watcher.handle(release)
        try await Task.sleep(for: .milliseconds(400))
        #expect(watcher.selection != nil)

        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let directory = try #require(ProcessInfo.processInfo.environment["RELEVO_RENDER_DIR"])
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(filePath: directory).appending(path: "relevo-code-quote.png"))
    }
}
