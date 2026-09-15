import AppKit
import SwiftUI

/// The popover owns one native scrolling surface; its search and footer remain outside it.
struct NativeScrollCommand {
    let id: UUID
    let y: CGFloat
}

struct NativeScrollView<Content: View>: NSViewRepresentable {
    var onScroll: ((CGFloat) -> Void)? = nil
    var scrollCommand: NativeScrollCommand? = nil
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let host = WheelHostingView(rootView: AnyView(content().fixedSize(horizontal: false, vertical: true)))
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.onScroll = onScroll
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
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
        (scroll.documentView as? WheelHostingView<AnyView>)?.rootView = AnyView(content().fixedSize(horizontal: false, vertical: true))
        if let command = scrollCommand, context.coordinator.lastCommandID != command.id {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, command.y)))
            scroll.reflectScrolledClipView(scroll.contentView)
            context.coordinator.lastCommandID = command.id
        }
    }

    final class Coordinator: NSObject {
        var onScroll: ((CGFloat) -> Void)?
        var lastCommandID: UUID?

        @objc func boundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            onScroll?(clipView.bounds.origin.y)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private final class WheelHostingView<Content: View>: NSHostingView<Content> {
    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}
