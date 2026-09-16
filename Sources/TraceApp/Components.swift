import AppKit
import Carbon
import SwiftUI
import TraceCore

enum TraceTheme {
    static let accent = Color(red: 0.35, green: 0.42, blue: 0.98)
    static let panelBackground = Color(nsColor: .windowBackgroundColor).opacity(0.96)
}

struct RowFramesPreference: PreferenceKey {
    static let defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

enum RowFrameGeometry {
    static func firstVisible(in frames: [Int64: CGRect], offset: CGFloat) -> (id: Int64, frame: CGRect)? {
        frames.filter { $0.value.maxY > offset + 1 }
            .min { $0.value.minY < $1.value.minY }
            .map { (id: $0.key, frame: $0.value) }
    }

    static func intersectsViewport(_ frame: CGRect, offset: CGFloat, height: CGFloat) -> Bool {
        height > 0 && frame.maxY > offset && frame.minY < offset + height
    }
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
    @State private var showingDetails = false
    private var busy: Bool { ![.waiting, .complete, .cancelled, .failed].contains(progress.phase) }

    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(label).font(.caption)
                    .foregroundStyle(progress.phase == .failed || progress.unresolvedFailedFiles > 0 ? .red : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("indexProgress")
        .help(details)
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text(label).font(.headline)
                if progress.totalFiles > 0 {
                    ProgressView(value: Double(progress.completedFiles), total: Double(progress.totalFiles))
                }
                Text(details).font(.callout).textSelection(.enabled)
                if progress.currentFileTotalBytes > 0 && busy {
                    ProgressView(value: Double(min(progress.currentFileBytes, progress.currentFileTotalBytes)), total: Double(progress.currentFileTotalBytes))
                }
            }.padding(18).frame(width: 380)
        }
    }

    private var details: String {
        var lines = ["\(progress.completedFiles.formatted()) of \(progress.totalFiles.formatted()) files checked",
            "\(progress.indexedFiles.formatted()) indexed · \(progress.unchangedFiles.formatted()) unchanged · \(progress.failedFiles.formatted()) failed"]
        if progress.unresolvedFailedFiles > 0 {
            lines.append("\(progress.unresolvedFailedFiles) files still failing")
        }
        if let agent = progress.agent { lines.append("Provider: \(agent.displayName)") }
        if let project = progress.projectName { lines.append("Project: \(project)") }
        if let path = progress.currentPath {
            lines.append(path)
            lines.append("\(ByteCountFormatter.string(fromByteCount: progress.currentFileBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.currentFileTotalBytes, countStyle: .file)) processed")
        }
        if let error = progress.error { lines.append(error) }
        if let warning = progress.metadataWarning { lines.append(warning) }
        if let rollupError = progress.rollupError { lines.append("Token totals: \(rollupError)") }
        return lines.joined(separator: "\n")
    }

    private var label: String {
        switch progress.phase {
        case .waiting: "Ready to build index"
        case .discovering: "Finding sessions…"
        case .indexing:
            "\(progress.incremental ? "Updating" : "Indexing") \(progress.agent?.displayName ?? "sessions") · \(progress.completedFiles.formatted())/\(progress.totalFiles.formatted()) files"
        case .reconciling: "Checking moved and deleted sessions…"
        case .aggregating: "Updating token totals…"
        case .complete:
            if progress.unresolvedFailedFiles > 0 {
                "Index updated · \(progress.unresolvedFailedFiles) files still failing"
            } else if progress.failedFiles > 0 {
                "Index updated · \(progress.failedFiles) failed files"
            } else if progress.rollupError != nil {
                "Index current · Token totals need retry"
            } else { "Index current · Watching for changes" }
        case .cancelled:
            progress.unresolvedFailedFiles > 0
                ? "Indexing stopped · \(progress.unresolvedFailedFiles) files still failing"
                : "Indexing stopped · Progress saved"
        case .failed: progress.error ?? "Indexing failed"
        }
    }
}

struct MarkdownText: View {
    let source: String
    var copyMessage: (() -> Void)? = nil
    @State private var rendered = AttributedString()

    var body: some View {
        SelectableMessageText(text: rendered, copyMessage: copyMessage)
            .task(id: source) {
                rendered = await Task.detached(priority: .userInitiated) {
                    let prose = source.replacingOccurrences(of: "<proposed_plan>", with: "")
                        .replacingOccurrences(of: "</proposed_plan>", with: "")
                    let parsed = try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .full))
                    return parsed?.characters.isEmpty == false ? parsed! : AttributedString(prose)
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

struct PlanBadge: View {
    var body: some View {
        Label("Plan", systemImage: "list.bullet.rectangle")
            .font(.caption2)
            .foregroundStyle(.purple)
            .accessibilityLabel("Generated plan")
            .help("This session contains an explicit generated plan.")
    }
}
