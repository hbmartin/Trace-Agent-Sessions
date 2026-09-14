import AppKit
import Carbon
import SwiftUI
import TraceCore

enum TraceTheme {
    static let accent = Color(red: 0.35, green: 0.42, blue: 0.98)
    static let panelBackground = Color(nsColor: .windowBackgroundColor).opacity(0.96)
}

struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Source: \(agent.displayName)")
    }

    private var color: Color {
        switch agent {
        case .claudeCode: .orange
        case .codex: .green
        case .gemini: .blue
        }
    }
}

struct IndexProgressLabel: View {
    let progress: IndexProgress

    var body: some View {
        HStack(spacing: 8) {
            if progress.phase != .complete && progress.phase != .failed {
                ProgressView().controlSize(.small)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(progress.phase == .failed ? .red : .secondary)
                .lineLimit(1)
        }
    }

    private var label: String {
        switch progress.phase {
        case .discovering: "Finding sessions…"
        case .indexing: "Indexing \(progress.completedFiles.formatted()) of \(progress.totalFiles.formatted()) files"
        case .reconciling: "Reconciling deleted and moved files…"
        case .aggregating: "Updating token totals…"
        case .complete: "Index is current"
        case .failed: progress.error ?? "Indexing failed"
        }
    }
}

struct MarkdownText: View {
    let source: String
    @State private var rendered = AttributedString()

    var body: some View {
        Text(rendered)
            .textSelection(.enabled)
            .task(id: source) {
                rendered = await Task.detached(priority: .userInitiated) {
                    (try? AttributedString(
                        markdown: source,
                        options: .init(interpretedSyntax: .full)
                    )) ?? AttributedString(source)
                }.value
            }
    }
}

struct HotkeyRecorderView: NSViewRepresentable {
    @ObservedObject var settings: AppSettings

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.displayName = settings.hotkeyDisplayName
        view.onRecord = { keyCode, modifiers in
            settings.setHotkey(keyCode: keyCode, modifiers: modifiers)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.displayName = settings.hotkeyDisplayName
    }
}

@MainActor
final class ShortcutRecorderView: NSView {
    var onRecord: ((UInt32, UInt32) -> Void)?
    var displayName = "⌘⇧Space" { didSet { label.stringValue = displayName } }
    private let label = NSTextField(labelWithString: "")
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 30) }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 5)
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        label.stringValue = "Type shortcut"
        window?.makeFirstResponder(self)
        updateAppearance()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        guard carbonFlags != 0 else {
            NSSound.beep()
            return
        }
        recording = false
        onRecord?(UInt32(event.keyCode), carbonFlags)
        updateAppearance()
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        label.stringValue = displayName
        updateAppearance()
        return super.resignFirstResponder()
    }

    private func updateAppearance() {
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

extension Int64 {
    var traceDate: String {
        Date(timeIntervalSince1970: Double(self) / 1_000).formatted(date: .abbreviated, time: .shortened)
    }
}
