import AppKit
import Carbon

@MainActor
final class HotkeyController {
    private let settings: AppSettings
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(settings: AppSettings, action: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.action = action
        installHandler()
        register()
        NotificationCenter.default.addObserver(
            forName: .traceHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.register()
            }
        }
    }

    private func installHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            traceHotkeyCallback,
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func register() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let identifier = EventHotKeyID(signature: fourCharacterCode("TRCE"), id: 1)
        RegisterEventHotKey(
            settings.hotkeyKeyCode,
            settings.hotkeyModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    fileprivate func invoke() { action() }
}

private func traceHotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in controller.invoke() }
    return noErr
}

private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
}
