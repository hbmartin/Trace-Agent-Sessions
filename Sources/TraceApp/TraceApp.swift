import AppKit
import SwiftUI

@main
struct TraceApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { PreferencesView(model: TraceEnvironment.shared.model) }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        NotificationCenter.default.post(name: .traceShowPreferences, object: nil)
                    }.keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = TraceEnvironment.shared
    private var statusController: StatusItemController?
    private var mainWindowController: MainWindowController?
    private var launcherController: LauncherPanelController?
    private var preferencesController: PreferencesWindowController?
    private var onboardingController: OnboardingWindowController?
    private var hotkeyController: HotkeyController?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        environment.model.start()

        let main = MainWindowController(model: environment.model)
        let launcher = LauncherPanelController(model: environment.model)
        let preferences = PreferencesWindowController(model: environment.model)
        mainWindowController = main
        launcherController = launcher
        preferencesController = preferences
        statusController = StatusItemController(model: environment.model)

        hotkeyController = HotkeyController(settings: environment.settings) {
            NotificationCenter.default.post(name: .traceShowLauncher, object: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(showMain), name: .traceShowMainWindow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showLauncher), name: .traceShowLauncher, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showPreferences), name: .traceShowPreferences, object: nil)

        if !environment.settings.onboardingComplete {
            let onboarding = OnboardingWindowController(model: environment.model) { [weak self] in
                self?.onboardingController?.close()
                self?.onboardingController = nil
                if ProcessInfo.processInfo.arguments.contains("--ui-show-main") { self?.mainWindowController?.show() }
                if ProcessInfo.processInfo.arguments.contains("--ui-show-popover") { self?.statusController?.showPopover() }
            }
            onboardingController = onboarding
            onboarding.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        if TraceRuntime.testDirectory != nil, environment.settings.onboardingComplete {
            if ProcessInfo.processInfo.arguments.contains("--ui-show-main") { main.show() }
            if ProcessInfo.processInfo.arguments.contains("--ui-show-settings") { preferences.show() }
            if ProcessInfo.processInfo.arguments.contains("--ui-show-popover") { statusController?.showPopover() }
        }

        if ProcessInfo.processInfo.arguments.contains("--network-smoke") {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await environment.model.prepareToTerminate()
                exit(EXIT_SUCCESS)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateNow }
        terminationPending = true
        Task {
            await environment.model.prepareToTerminate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func showMain() { mainWindowController?.show() }
    @objc private func showLauncher() { launcherController?.show() }
    @objc private func showPreferences() { preferencesController?.show() }
}
