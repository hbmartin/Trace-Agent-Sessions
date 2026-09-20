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
                    .foregroundStyle(progress.phase == .failed || hasUnresolvedFailures ? .red : .secondary)
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
        var lines = [activityDescription,
            "\(progress.completedFiles.formatted()) of \(progress.totalFiles.formatted()) files checked",
            "\(progress.indexedFiles.formatted()) indexed · \(progress.unchangedFiles.formatted()) unchanged · \(progress.failedFiles.formatted()) failed"]
        if progress.unresolvedFailedFiles > 0 {
            lines.append("\(progress.unresolvedFailedFiles) files still failing")
        }
        if progress.unresolvedDiscoveryFailures > 0 {
            lines.append("\(progress.unresolvedDiscoveryFailures) source locations still unavailable")
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
        case .discovering:
            switch progress.activity {
            case .initialBuild: "Building index…"
            case .launchCatchUp: "Catching up on changes…"
            case .launchReconciliation: "Reconciling cached index…"
            case .cachedLaunch: "Opening cached index…"
            case .fileChanges: "Checking changed files…"
            case .subtreeRecovery: "Checking changed folder…"
            case .rootRecovery: "Checking changed source root…"
            case .eventStreamRecovery: "Recovering file-event history…"
            case .safetyVerification: "Running daily index check…"
            case .rebuild: "Rebuilding index…"
            case .scopeChange: "Updating indexed content…"
            }
        case .indexing:
            "\(progress.activity == .initialBuild || progress.activity == .rebuild ? "Indexing" : "Updating") \(progress.agent?.displayName ?? "sessions") · \(progress.completedFiles.formatted())/\(progress.totalFiles.formatted()) files"
        case .reconciling:
            progress.activity == .safetyVerification
                ? "Verifying cached index…"
                : "Checking moved and deleted sessions…"
        case .aggregating: "Updating token totals…"
        case .complete:
            if hasUnresolvedFailures {
                "Index updated · \(unresolvedSummary)"
            } else if progress.failedFiles > 0 {
                "Index updated · \(progress.failedFiles) failed files"
            } else if progress.rollupError != nil {
                "Index current · Token totals need retry"
            } else { "Index current · Watching for changes" }
        case .cancelled:
            hasUnresolvedFailures
                ? "Indexing stopped · \(unresolvedSummary)"
                : "Indexing stopped · Progress saved"
        case .failed: progress.error ?? "Indexing failed"
        }
    }

    private var hasUnresolvedFailures: Bool {
        progress.unresolvedFailedFiles > 0 || progress.unresolvedDiscoveryFailures > 0
    }

    private var unresolvedSummary: String {
        var parts: [String] = []
        if progress.unresolvedFailedFiles > 0 {
            parts.append("\(progress.unresolvedFailedFiles) files still failing")
        }
        if progress.unresolvedDiscoveryFailures > 0 {
            parts.append("\(progress.unresolvedDiscoveryFailures) source locations unavailable")
        }
        return parts.joined(separator: " · ")
    }

    private var activityDescription: String {
        switch progress.activity {
        case .initialBuild: "Initial index build"
        case .launchCatchUp: "Launch catch-up from saved file-event checkpoint"
        case .launchReconciliation: "Launch reconciliation after establishing a new file-event checkpoint"
        case .cachedLaunch: "Loaded the persisted index without a full scan"
        case .fileChanges: "Incremental file-system update"
        case .subtreeRecovery: "Scoped folder reconciliation"
        case .rootRecovery: "Scoped source-root reconciliation"
        case .eventStreamRecovery: "Recovery after dropped or wrapped file events"
        case .safetyVerification: "Daily safety reconciliation"
        case .rebuild: "User-requested full rebuild"
        case .scopeChange: "Rebuild required by index-scope change"
        }
    }
}

struct MarkdownText: View {
    let source: String
    var copyMessage: (() -> Void)?
    var heightChanged: (() -> Void)?
    @State private var rendered = AttributedString()

    var body: some View {
        SelectableMessageText(text: rendered, copyMessage: copyMessage)
            .task(id: source) {
                let value = await MarkdownRenderCache.shared.render(source)
                guard value != rendered else { return }
                rendered = value
                heightChanged?()
            }
    }
}

private actor MarkdownRenderCache {
    static let shared = MarkdownRenderCache()
    private var values: [String: AttributedString] = [:]
    private var order: [String] = []
    private let limit = 1_024

    func render(_ source: String) -> AttributedString {
        if let cached = values[source] { return cached }
        let prose = source.replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
        let parsed = try? AttributedString(
            markdown: prose, options: .init(interpretedSyntax: .full)
        )
        let rendered = parsed?.characters.isEmpty == false ? parsed! : AttributedString(prose)
        values[source] = rendered
        order.append(source)
        if order.count > limit {
            let overflow = order.count - limit
            let evicted = Array(order.prefix(overflow))
            order.removeFirst(overflow)
            for key in evicted { values.removeValue(forKey: key) }
        }
        return rendered
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
