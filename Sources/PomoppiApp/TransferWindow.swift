import AppKit
import SwiftUI
import PomoppiStrings

// The Pomoppi tab's Transfer window (SPEC.md §16): its own resizable window,
// one instance, reopened to the front like the Diary viewer. The content is
// rebuilt each time the window is opened from closed, so Send's snapshot of
// the settings and log is fresh; reopening an already-open window keeps it.
final class TransferWindowController {
    private let viewModel: SettingsViewModel
    private var window: NSWindow?

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 460, height: 520)
            window.setFrameAutosaveName("pomoppi.transferWindow")
            if !window.setFrameUsingName("pomoppi.transferWindow") { window.center() }
            self.window = window
        }
        // Set on every open so a language change since the last one shows.
        window?.title = L.t("transfer.windowTitle")
        if let window, !window.isVisible {
            // Only the minimum comes from SwiftUI, the user owns the rest.
            let hostingView = NSHostingView(rootView: TransferView(viewModel: viewModel))
            hostingView.sizingOptions = [.minSize]
            window.contentView = hostingView
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
