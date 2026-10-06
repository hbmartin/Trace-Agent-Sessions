import Foundation

public struct SidebarRevealProgress {
    private var previous: (row: Int, rect: CGRect, viewport: CGRect)?
    private var stableChecks = 0
    public init() {}
    public mutating func observe(row: Int, rect: CGRect, viewport: CGRect) -> Bool {
        let visible = viewport.intersection(rect)
        let fullyVisible = !rect.isEmpty && visible.height >= rect.height - 1 && visible.width >= rect.width - 1
        let unchanged = previous.map { $0.row == row && $0.rect == rect && $0.viewport == viewport } ?? true
        stableChecks = fullyVisible ? (unchanged ? stableChecks + 1 : 1) : 0
        previous = (row, rect, viewport)
        return stableChecks >= 3
    }
}
