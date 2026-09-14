import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: TraceModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    init(model: TraceModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 520)
        popover.contentViewController = NSHostingController(rootView: RecentPopoverView(model: model))
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Trace")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        if event.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem.menu = contextMenu()
            button.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Trace", action: #selector(openTrace), keyEquivalent: "")
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rebuild Index…", action: #selector(rebuild), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Trace", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func openTrace() { NotificationCenter.default.post(name: .traceShowMainWindow, object: nil) }
    @objc private func openPreferences() { NotificationCenter.default.post(name: .traceShowPreferences, object: nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func rebuild() {
        let alert = NSAlert()
        alert.messageText = "Rebuild Trace’s index?"
        alert.informativeText = "The disposable local index will be recreated from your session files. Source files are never modified."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.rebuildIndex() }
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    init(model: TraceModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Trace"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 880, height: 560)
        window.center()
        window.contentView = NSHostingView(rootView: MainView(model: model))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LauncherPanelController: NSWindowController, NSWindowDelegate {
    init(model: TraceModel) {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LauncherView(model: model))
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let panel = window else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.midY - frame.height / 2 + 80
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResignKey(_ notification: Notification) { window?.orderOut(nil) }
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    init(model: TraceModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trace Preferences"
        window.center()
        window.contentView = NSHostingView(rootView: PreferencesView(model: model))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(model: TraceModel, completion: @escaping @MainActor () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Trace"
        window.titlebarAppearsTransparent = true
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, completion: completion))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }
}
