import AppKit
import SwiftUI

/// Native text keeps selection, links, and a message-level copy command in one menu.
struct SelectableMessageText: NSViewRepresentable {
    let text: AttributedString
    var monospaced = false
    var secondary = false
    var copyMessage: (() -> Void)?

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
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.copyMessage = copyMessage
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
        if view.textStorage?.isEqual(to: styled) != true {
            view.textStorage?.setAttributedString(styled)
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 600)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(18, ceil(layout.usedRect(for: container).height)))
    }
}

final class MessageTextView: NSTextView {
    var copyMessage: (() -> Void)?

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> String? { string }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if copyMessage != nil {
            let item = NSMenuItem(title: "Copy Message", action: #selector(copyWholeMessage), keyEquivalent: "")
            item.target = self
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func copyWholeMessage() { copyMessage?() }
}
