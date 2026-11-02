import AppKit
import Observation
import SwiftUI

@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()

    public init(model: AppModel) {
        self.model = model
        super.init()
        popover.delegate = self
        popover.hasFullSizeContent = true
        popover.animates = false
        item.button?.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Relevo")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        followProgress()
    }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            let content = NSHostingController(rootView: MenuView(model: model))
            content.sizingOptions = .preferredContentSize
            popover.contentViewController = content
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            content.view.window?.makeKey()
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func followProgress() {
        let busy = withObservationTracking {
            model.progress != nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.followProgress() }
        }
        popover.behavior = busy ? .applicationDefined : .transient
        if !busy, !NSApp.isActive {
            popover.performClose(nil)
        }
    }
}
