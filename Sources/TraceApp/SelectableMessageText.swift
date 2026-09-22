import AppKit
import SwiftUI

/// Native text owns selection and its standard editing menu. Keeping the menu entirely in
/// NSTextView prevents SwiftUI row gestures from cancelling a drag selection.
struct SelectableMessageText: NSViewRepresentable {
    let text: AttributedString
    var monospaced = false
    var secondary = false
    var copyMessage: (() -> Void)?

    final class Coordinator {
        let measurementStorage = NSTextStorage()
        let measurementLayout = NSLayoutManager()
        let measurementContainer = NSTextContainer()
        var lastText: AttributedString?
        var lastMonospaced = false
        var lastSecondary = false

        init() {
            measurementContainer.lineFragmentPadding = 0
            measurementContainer.widthTracksTextView = false
            measurementLayout.addTextContainer(measurementContainer)
            measurementStorage.addLayoutManager(measurementLayout)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MessageTextView {
        let view = MessageTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.copyMessage = copyMessage
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.copyMessage = copyMessage
        guard context.coordinator.lastText != text
                || context.coordinator.lastMonospaced != monospaced
                || context.coordinator.lastSecondary != secondary else { return }
        let styled = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let range = NSRange(location: 0, length: styled.length)
        styled.addAttributes([
            .font: monospaced ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13),
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
        ], range: range)
        var offset = 0
        for run in text.runs {
            let length = String(text[run.range].characters).utf16.count
            if let intent = run.inlinePresentationIntent {
                var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13)
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                styled.addAttribute(.font, value: font, range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        view.textStorage?.setAttributedString(styled)
        context.coordinator.measurementStorage.setAttributedString(styled)
        context.coordinator.lastText = text
        context.coordinator.lastMonospaced = monospaced
        context.coordinator.lastSecondary = secondary
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        let fallbackWidth = nsView.bounds.width > 0 ? nsView.bounds.width : nil
        guard let width = proposal.width ?? fallbackWidth,
              width.isFinite,
              width > 0 else { return nil }
        let container = context.coordinator.measurementContainer
        let layout = context.coordinator.measurementLayout
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(18, ceil(layout.usedRect(for: container).height)))
    }
}

final class MessageTextView: NSTextView {
    var copyMessage: (() -> Void)?

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> String? { string }

    override func scrollWheel(with event: NSEvent) {
        if let enclosingScrollView { enclosingScrollView.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        // NSTableView otherwise has an opportunity to reclaim first responder
        // from its hosted text during row interaction, which breaks native text
        // selection and routes Copy to the row instead of the selected text.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard copyMessage != nil else { return super.menu(for: event) }
        // NSTextView may return a shared menu. Copy it so this row's action never
        // accumulates or retains the callback from a previously opened row.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(
            title: "Copy Message", action: #selector(copyWholeMessage), keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyWholeMessage() {
        copyMessage?()
    }
}
