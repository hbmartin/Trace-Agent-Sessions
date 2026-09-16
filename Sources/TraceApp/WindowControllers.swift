import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: TraceModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    init(model: TraceModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 480, height: 600)
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
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? NSSize(width: 480, height: 640)
        popover.contentSize = NSSize(width: min(480, available.width - 24), height: min(600, available.height - 40))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        model.setGlobalSearchSurface(.popover, visible: true)
        popover.contentViewController?.view.window?.makeKey()
        NotificationCenter.default.post(name: .traceFocusPopover, object: nil)
    }

    func popoverDidClose(_ notification: Notification) {
        model.setGlobalSearchSurface(.popover, visible: false)
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
    private var titleObservation: AnyCancellable?
    private let model: TraceModel
    init(model: TraceModel) {
        self.model = model
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
        titleObservation = model.objectWillChange.sink { [weak self, weak model] in
            Task { @MainActor in
                guard let model else { return }
                self?.window?.title = model.detailTitle
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.setMainWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.setMainWindowVisible(false)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMiniaturize(_ notification: Notification) { model.setMainWindowVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.setMainWindowVisible(true) }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            NotificationCenter.default.post(name: .traceHideLauncher, object: nil)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .traceHideLauncher, object: nil)
    }
}

@MainActor
final class LauncherPanelController: NSWindowController, NSWindowDelegate {
    private let model: TraceModel
    init(model: TraceModel) {
        self.model = model
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
            hide()
            return
        }
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.midY - frame.height / 2 + 80
            ))
        }
        model.setGlobalSearchSurface(.launcher, visible: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        model.setGlobalSearchSurface(.launcher, visible: false)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
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
        window.title = "Trace Settings"
        window.minSize = NSSize(width: 640, height: 600)
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
