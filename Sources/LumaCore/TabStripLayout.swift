import CoreGraphics

/// Where the tabs of the tab strip sit, and what a click on the strip means. Pure geometry.
///
/// Tabs never shrink below a readable width. When they no longer fit, the strip scrolls sideways
/// instead, so a tab's close box can never grow to cover most of the tab.
public struct TabStripLayout: Equatable {
    public static let minimumTabWidth: CGFloat = 96
    public static let maximumTabWidth: CGFloat = 220
    public static let closeBoxSize: CGFloat = 16
    /// Space between a tab's left edge and its close box.
    public static let closeBoxInset: CGFloat = 8

    public let count: Int
    public let width: CGFloat
    public let height: CGFloat
    public let tabWidth: CGFloat
    /// How far the tabs are scrolled to the left. Always within what there is to scroll.
    public let scrollOffset: CGFloat

    public init(count: Int, width: CGFloat, height: CGFloat, scrollOffset: CGFloat = 0) {
        self.count = max(0, count)
        self.width = max(0, width)
        self.height = max(0, height)
        let even = self.count > 0 ? self.width / CGFloat(self.count) : 0
        self.tabWidth = self.count > 0 ? min(TabStripLayout.maximumTabWidth, max(TabStripLayout.minimumTabWidth, even)) : 0
        let furthest = max(0, tabWidth * CGFloat(self.count) - self.width)
        self.scrollOffset = min(max(scrollOffset, 0), furthest)
    }

    public var maximumScrollOffset: CGFloat { max(0, tabWidth * CGFloat(count) - width) }

    /// The tab's frame in the strip's own coordinates; it may lie partly or wholly outside the strip.
    public func tabFrame(_ index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * tabWidth - scrollOffset, y: 0, width: tabWidth, height: height)
    }

    public func closeBox(_ index: Int) -> CGRect {
        let frame = tabFrame(index)
        let size = TabStripLayout.closeBoxSize
        return CGRect(x: frame.minX + TabStripLayout.closeBoxInset, y: (height - size) / 2, width: size, height: size)
    }

    public enum Hit: Equatable {
        case select(Int)
        case close(Int)
        case nothing
    }

    /// What a click at `point` does. A close box only works on tabs where it is showing.
    public func hit(at point: CGPoint, closeBoxShowingOn showing: Set<Int>) -> Hit {
        guard tabWidth > 0, point.x >= 0, point.x < width, point.y >= 0, point.y < height else { return .nothing }
        let index = Int(((point.x + scrollOffset) / tabWidth).rounded(.down))
        guard index >= 0, index < count else { return .nothing }
        if showing.contains(index) && closeBox(index).contains(point) { return .close(index) }
        return .select(index)
    }

    /// The scroll offset that brings the whole tab into view, moving as little as possible.
    public func scrollOffset(revealing index: Int) -> CGFloat {
        guard index >= 0, index < count else { return scrollOffset }
        let left = CGFloat(index) * tabWidth
        var offset = scrollOffset
        if left < offset { offset = left }
        if left + tabWidth > offset + width { offset = left + tabWidth - width }
        return min(max(offset, 0), maximumScrollOffset)
    }
}
