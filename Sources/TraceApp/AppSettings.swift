import Carbon
import Combine
import Foundation
import ServiceManagement
import TraceCore

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let indexScope = "indexScope"
        static let searchSort = "searchSort"
        static let clearGlobalSearchOnClose = "clearGlobalSearchOnClose"
        static let clearGlobalFiltersOnClose = "clearGlobalFiltersOnClose"
        static let additionalClaudeRoots = "additionalClaudeRoots"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let lastSessionID = "lastSessionID"
        static let lastScrollMessageID = "lastScrollMessageID"
        static let includeSidechains = "includeSidechains"
        static let costRange = "costRange"
    }

    @Published var showTools: Bool { didSet { defaults.set(showTools, forKey: "showTools") } }
    @Published var showSystem: Bool { didSet { defaults.set(showSystem, forKey: "showSystem") } }
    @Published var showReasoning: Bool { didSet { defaults.set(showReasoning, forKey: "showReasoning") } }
    @Published var transcriptDensity: TranscriptDensity { didSet { defaults.set(transcriptDensity.rawValue, forKey: "transcriptDensity") } }

    var transcriptVisibility: TranscriptVisibility {
        .init(tools: showTools, system: showSystem, reasoning: showReasoning)
    }

    private let defaults: UserDefaults

    @Published var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) } }
    @Published var indexScope: IndexScope { didSet { defaults.set(indexScope.rawValue, forKey: Key.indexScope) } }
    @Published var searchSort: SearchSort { didSet { defaults.set(searchSort.rawValue, forKey: Key.searchSort) } }
    @Published var clearGlobalSearchOnClose: Bool {
        didSet { defaults.set(clearGlobalSearchOnClose, forKey: Key.clearGlobalSearchOnClose) }
    }
    @Published var clearGlobalFiltersOnClose: Bool {
        didSet { defaults.set(clearGlobalFiltersOnClose, forKey: Key.clearGlobalFiltersOnClose) }
    }
    @Published var additionalClaudeRoots: [String] { didSet { defaults.set(additionalClaudeRoots, forKey: Key.additionalClaudeRoots) } }
    @Published var hotkeyKeyCode: UInt32 { didSet { defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode) } }
    @Published var hotkeyModifiers: UInt32 { didSet { defaults.set(Int(hotkeyModifiers), forKey: Key.hotkeyModifiers) } }
    @Published var lastSessionID: Int64? {
        didSet {
            if let lastSessionID { defaults.set(lastSessionID, forKey: Key.lastSessionID) }
            else { defaults.removeObject(forKey: Key.lastSessionID) }
        }
    }
    @Published var projectPaneFraction: Double {
        didSet { defaults.set(projectPaneFraction, forKey: "projectPaneFraction") }
    }
    @Published var includeSidechains: Bool { didSet { defaults.set(includeSidechains, forKey: Key.includeSidechains) } }
    @Published var costRange: CostRange { didSet { defaults.set(costRange.rawValue, forKey: Key.costRange) } }

    init(defaults: UserDefaults = TraceRuntime.defaults) {
        self.defaults = defaults
        showTools = defaults.object(forKey: "showTools") as? Bool ?? true
        showSystem = defaults.object(forKey: "showSystem") as? Bool ?? true
        showReasoning = defaults.object(forKey: "showReasoning") as? Bool ?? true
        transcriptDensity = TranscriptDensity(rawValue: defaults.string(forKey: "transcriptDensity") ?? "") ?? .comfortable
        let arguments = ProcessInfo.processInfo.arguments
        onboardingComplete = arguments.contains("--ui-onboarding") || arguments.contains("--network-smoke")
            ? false
            : defaults.bool(forKey: Key.onboardingComplete)
        if TraceRuntime.testDirectory != nil && arguments.contains("--index-smoke") { onboardingComplete = true }
        indexScope = IndexScope(rawValue: defaults.object(forKey: Key.indexScope) as? Int ?? 0) ?? .proseOnly
        searchSort = SearchSort(rawValue: defaults.string(forKey: Key.searchSort) ?? "") ?? .recency
        clearGlobalSearchOnClose = defaults.object(forKey: Key.clearGlobalSearchOnClose) as? Bool ?? true
        clearGlobalFiltersOnClose = defaults.object(forKey: Key.clearGlobalFiltersOnClose) as? Bool ?? true
        let storedClaudeRoots = defaults.stringArray(forKey: Key.additionalClaudeRoots) ?? []
        let defaultClaudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let normalizedClaudeRoots = ClaudeCodeSource(
            roots: [defaultClaudeRoot] + storedClaudeRoots.map { URL(fileURLWithPath: $0) }
        ).roots.filter { !$0.isDefault }.map(\.url.path)
        additionalClaudeRoots = normalizedClaudeRoots
        if normalizedClaudeRoots != storedClaudeRoots {
            defaults.set(normalizedClaudeRoots, forKey: Key.additionalClaudeRoots)
        }
        hotkeyKeyCode = UInt32(defaults.object(forKey: Key.hotkeyKeyCode) as? Int ?? kVK_Space)
        hotkeyModifiers = UInt32(defaults.object(forKey: Key.hotkeyModifiers) as? Int ?? (cmdKey | shiftKey))
        lastSessionID = defaults.object(forKey: Key.lastSessionID) as? Int64
        projectPaneFraction = defaults.object(forKey: "projectPaneFraction") as? Double ?? 0.4
        defaults.removeObject(forKey: Key.lastScrollMessageID)
        includeSidechains = defaults.bool(forKey: Key.includeSidechains)
        costRange = CostRange(rawValue: defaults.string(forKey: Key.costRange) ?? "") ?? .thirtyDays
    }

    var hotkeyDisplayName: String {
        var parts: [String] = []
        if hotkeyModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if hotkeyModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hotkeyModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hotkeyModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: hotkeyKeyCode))
        return parts.joined()
    }

    func setHotkey(keyCode: UInt32, modifiers: UInt32) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        NotificationCenter.default.post(name: .traceHotkeyChanged, object: nil)
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard TraceRuntime.testDirectory == nil else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    var launchAtLoginEnabled: Bool { TraceRuntime.testDirectory == nil && SMAppService.mainApp.status == .enabled }
}

enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        if let letter = letterNames[Int(keyCode)] { return letter }
        if let number = numberNames[Int(keyCode)] { return number }
        if Int(keyCode) == kVK_Space { return "Space" }
        if Int(keyCode) == kVK_Return { return "Return" }
        return "Key \(keyCode)"
    }

    private static let letterNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
    ]
    private static let numberNames: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]
}

extension Notification.Name {
    static let traceShowMainWindow = Notification.Name("TraceShowMainWindow")
    static let traceShowLauncher = Notification.Name("TraceShowLauncher")
    static let traceHideLauncher = Notification.Name("TraceHideLauncher")
    static let traceHotkeyChanged = Notification.Name("TraceHotkeyChanged")
    static let traceShowPreferences = Notification.Name("TraceShowPreferences")
}

enum TranscriptDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// UI tests use a separate database, source roots, preferences, and diagnostics directory.
enum TraceRuntime {
    static let testDirectory: URL? = {
        if let path = ProcessInfo.processInfo.environment["TRACE_TEST_DIRECTORY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing") || args.contains("--network-smoke") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TraceIsolated-\(UUID())", isDirectory: true)
        }
        return nil
    }()
    static var defaults: UserDefaults {
        if let directory = testDirectory { return UserDefaults(suiteName: "me.haroldmartin.Trace.tests.\(directory.lastPathComponent)")! }
        return .standard
    }
}
