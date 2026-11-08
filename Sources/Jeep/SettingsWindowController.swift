import AppKit
import SwiftUI

/// Owns Jeep's only regular window. SwiftUI's `Settings` scene can't be
/// opened from AppKit on macOS 14+ (`showSettingsWindow:` is a no-op), so
/// launch, reopen, and the menu all come through here.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Set once at startup, before any window is shown.
    weak var model: SwitcherModel?

    private enum Content {
        case welcome
        case settings
    }

    private static let settingsFrameName = "JeepSettingsWindow"

    private var window: NSWindow?
    private var content: Content?

    private override init() {
        super.init()
    }

    /// Opens Settings. Until the user has started Jeep, the welcome screen
    /// stands in for Settings so nothing can begin hiding windows without
    /// the user's confirmation.
    func showSettings() {
        guard let model else {
            return
        }

        present(model.hasCompletedOnboarding ? .settings : .welcome, model: model)
    }

    func showWelcome() {
        guard let model else {
            return
        }

        present(.welcome, model: model)
    }

    func close() {
        window?.close()
    }

    private func present(_ newContent: Content, model: SwitcherModel) {
        let window = window ?? makeWindow()
        self.window = window

        if content != newContent {
            content = newContent
            install(newContent, in: window, model: model)
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app's activation request can be declined on macOS 14+;
        // the window must still come forward for a user who asked for it.
        window.orderFrontRegardless()
    }

    private func install(_ content: Content, in window: NSWindow, model: SwitcherModel) {
        switch content {
        case .welcome:
            window.setFrameAutosaveName("")
            window.title = "Welcome to Jeep"
            window.styleMask.insert(.resizable)
            window.contentViewController = NSHostingController(
                rootView: WelcomeView(model: model) { [weak self] in
                    self?.close()
                }
            )
            if let screen = window.screen ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                let availableContent = window.contentRect(forFrameRect: visibleFrame)
                let contentRect = NSRect(
                    x: 0, y: 0,
                    width: min(480, availableContent.width),
                    height: min(720, availableContent.height)
                )
                var frame = window.frameRect(forContentRect: contentRect)
                frame.origin = NSPoint(
                    x: visibleFrame.midX - frame.width / 2,
                    y: visibleFrame.midY - frame.height / 2
                )
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
        case .settings:
            window.title = "Jeep Settings"
            window.styleMask.insert(.resizable)
            window.contentViewController = NSHostingController(
                rootView: SettingsView(model: model)
            )
            if !window.setFrameUsingName(Self.settingsFrameName) {
                window.center()
            }
            window.setFrameAutosaveName(Self.settingsFrameName)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = JeepSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the hosted view so observation and polling stop while closed;
        // the next show rebuilds it.
        window?.contentViewController = nil
        content = nil
    }
}

/// Closes on Esc and ⌘W even though an accessory app has no File menu.
private final class JeepSettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
