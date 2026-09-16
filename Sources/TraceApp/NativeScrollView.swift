import AppKit
import SwiftUI
import TraceCore

/// The popover owns one native scrolling surface; its search and footer remain outside it.
struct NativeScrollCommand {
    let id: UUID
    let resultSetID: UUID
    let y: CGFloat
}

struct NativeScrollView<Content: View>: NSViewRepresentable {
    var onScroll: ((CGFloat) -> Void)? = nil
    var onUserScroll: (() -> Void)? = nil
    var scrollCommand: NativeScrollCommand? = nil
    var testKeyboardScrollRequestID: UUID? = nil
    var resultSetID: UUID? = nil
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = UserObservedScrollView()
        scroll.onUserScroll = onUserScroll
        scroll.hasVerticalScroller = true
        let scroller = UserObservedScroller()
        scroller.onUserScroll = onUserScroll
        scroller.setAccessibilityIdentifier("searchResultsScroller")
        scroll.verticalScroller = scroller
        scroll.drawsBackground = false
        scroll.autohidesScrollers = !TraceTestHooks.isUITesting
        let host = WheelHostingView(rootView: AnyView(content().fixedSize(horizontal: false, vertical: true)))
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.onScroll = onScroll
        context.coordinator.onUserScroll = onUserScroll
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.userScrollStarted(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll
        )
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            host.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onUserScroll = onUserScroll
        (scroll as? UserObservedScrollView)?.onUserScroll = onUserScroll
        (scroll.verticalScroller as? UserObservedScroller)?.onUserScroll = onUserScroll
        (scroll.documentView as? WheelHostingView<AnyView>)?.rootView = AnyView(content().fixedSize(horizontal: false, vertical: true))
        if let request = testKeyboardScrollRequestID,
           context.coordinator.lastTestKeyboardScrollRequestID != request,
           let observed = scroll as? UserObservedScrollView {
            context.coordinator.lastTestKeyboardScrollRequestID = request
            DispatchQueue.main.async { observed.sendTestPageDown() }
        }
        if let command = scrollCommand, command.resultSetID == resultSetID,
           context.coordinator.lastCommandID != command.id {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, command.y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            context.coordinator.lastCommandID = command.id
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onScroll: ((CGFloat) -> Void)?
        var onUserScroll: (() -> Void)?
        var lastCommandID: UUID?
        var lastTestKeyboardScrollRequestID: UUID?
        private var pendingY: CGFloat?
        private var deliveryScheduled = false

        @objc func boundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            pendingY = clipView.bounds.origin.y
            guard !deliveryScheduled else { return }
            deliveryScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deliveryScheduled = false
                if let y = self.pendingY {
                    self.pendingY = nil
                    TraceTestHooks.appendLine(
                        String(Double(y)), pathKey: "TRACE_TEST_NATIVE_SCROLL_OFFSET_PATH"
                    )
                    self.onScroll?(y)
                }
            }
        }

        @objc func userScrollStarted(_ notification: Notification) {
            onUserScroll?()
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private final class UserObservedScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126, 115, 116, 119, 121].contains(event.keyCode) {
            TraceTestHooks.appendLine(
                "keyboard", pathKey: "TRACE_TEST_NATIVE_KEYBOARD_SCROLL_PATH"
            )
            onUserScroll?()
        }
        super.keyDown(with: event)
    }

    func sendTestPageDown() {
        let pageDown = String(UnicodeScalar(NSPageDownFunctionKey)!)
        guard TraceTestHooks.isUITesting,
              let event = NSEvent.keyEvent(
                  with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                  windowNumber: window?.windowNumber ?? 0, context: nil,
                  characters: pageDown, charactersIgnoringModifiers: pageDown, isARepeat: false,
                  keyCode: 121
              ) else { return }
        keyDown(with: event)
        let origin = contentView.bounds.origin
        contentView.scroll(to: NSPoint(
            x: origin.x,
            y: origin.y + max(1, contentView.bounds.height * 0.9)
        ))
        reflectScrolledClipView(contentView)
    }
}

private final class UserObservedScroller: NSScroller {
    var onUserScroll: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let scroll = enclosingScrollView
        onUserScroll?()
        super.mouseDown(with: event)
        if let scroll { window?.makeFirstResponder(scroll) }
    }

}

private final class WheelHostingView<Content: View>: NSHostingView<Content> {
    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}
