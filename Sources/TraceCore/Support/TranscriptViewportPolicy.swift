import Foundation

/// Shared geometry decisions, independent of AppKit's asynchronous notifications.
public enum TranscriptViewportPolicy {
    public static func maximumOrigin(frameHeight: CGFloat, lastRowBottom: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, max(frameHeight, lastRowBottom) - viewportHeight)
    }
    public static func matchesResizeShift(actual: CGFloat, previous: CGFloat, viewportDelta: CGFloat) -> Bool {
        abs(actual - previous + viewportDelta) <= 1
    }
    public static func followsBottom(atBottom: Bool, withinBounds: Bool, upwardTravel: CGFloat, previouslyFollowing: Bool) -> Bool {
        if atBottom { return true }
        if withinBounds && upwardTravel > 0.5 { return false }
        return previouslyFollowing
    }
}
