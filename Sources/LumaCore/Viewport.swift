import CoreGraphics

/// Arithmetic for the scrolling viewport, kept apart from the window so that it can be tested.
public enum Viewport {
    /// Where to scroll so that `anchor` appears `offset` points from the viewport's top-left corner.
    /// The result never scrolls past the content; with no anchor it is the top, centred horizontally.
    public static func origin(placing anchor: PageLayout.Anchor?, at offset: CGPoint,
                              in layout: PageLayout, viewportSize: CGSize) -> CGPoint {
        let furthest = CGPoint(x: max(0, layout.contentSize.width - viewportSize.width),
                               y: max(0, layout.contentSize.height - viewportSize.height))
        var origin = CGPoint(x: furthest.x / 2, y: 0)
        if let anchor {
            let point = layout.point(for: anchor)
            origin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
        }
        return CGPoint(x: min(max(origin.x, 0), furthest.x), y: min(max(origin.y, 0), furthest.y))
    }
}

/// Arithmetic for the list of open tabs.
public enum TabList {
    /// Which tab is selected once the tab at `closed` is gone, counted in the shortened list.
    /// Nil when no tab is left. `count` is the number of tabs before closing.
    public static func selection(afterClosing closed: Int, selected: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        let remaining = count - 1
        guard closed >= 0, closed < count else { return min(max(selected, 0), remaining - 1) }
        if closed < selected { return selected - 1 }
        // Closing the selected tab moves to the one that takes its place, or to the new last one.
        return min(max(selected, 0), remaining - 1)
    }
}
