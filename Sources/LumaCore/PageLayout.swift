import CoreGraphics

/// Where each page sits on the scrolling canvas. Pure geometry: it knows nothing about PDF or drawing.
///
/// Canvas coordinates have their origin at the top-left and y growing downward, like the page itself
/// is read. Pages are stacked in one column and centred horizontally.
public struct PageLayout: Equatable {
    /// Space between two pages, and around the whole column. It does not change with the scale.
    public static let gap: CGFloat = 12

    public let frames: [CGRect]
    public let contentSize: CGSize
    public let scale: CGFloat

    /// - Parameter pageSizes: each page's size on screen at scale 1 (rotation already applied).
    public init(pageSizes: [CGSize], scale: CGFloat, viewportWidth: CGFloat) {
        self.scale = scale
        let gap = PageLayout.gap
        let widest = (pageSizes.map(\.width).max() ?? 0) * scale
        let width = max(viewportWidth, widest + 2 * gap)
        var frames: [CGRect] = []
        var y = gap
        for size in pageSizes {
            let w = max(0, size.width * scale), h = max(0, size.height * scale)
            // Whole-point origins keep page edges sharp.
            frames.append(CGRect(x: ((width - w) / 2).rounded(.down), y: y.rounded(.down), width: w, height: h))
            y += h + gap
        }
        self.frames = frames
        self.contentSize = CGSize(width: width, height: frames.isEmpty ? 0 : y)
    }

    /// The scale at which the widest page exactly fills the viewport, leaving the gap on both sides.
    public static func fitWidthScale(pageSizes: [CGSize], viewportWidth: CGFloat) -> CGFloat {
        guard let widest = pageSizes.map(\.width).max(), widest > 0 else { return 1 }
        let scale = (viewportWidth - 2 * gap) / widest
        guard scale.isFinite else { return 1 }
        // Fitting may go below the smallest scale the zoom buttons reach: a poster in a narrow window must still fit.
        return min(max(scale, Zoom.fitMinimum), Zoom.maximum)
    }

    /// The page this height belongs to. A page owns everything from its own top edge down to the next
    /// page's top edge, so the gap below a page is part of it; anything above the first page counts
    /// as the first page.
    public func pageIndex(atY y: CGFloat) -> Int? {
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count - 1
        while low < high {
            let middle = (low + high) / 2
            if y < frames[middle + 1].minY { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// The pages that overlap a rectangle vertically, as a range that may be empty.
    public func pages(intersecting rect: CGRect) -> Range<Int> {
        guard let first = pageIndex(atY: rect.minY), let last = pageIndex(atY: rect.maxY) else { return 0..<0 }
        // `first` may only own the gap the rectangle starts in, and `last` may start below where it ends.
        let lower = frames[first].maxY <= rect.minY ? first + 1 : first
        let upper = frames[last].minY >= rect.maxY ? last - 1 : last
        return lower <= upper ? lower..<(upper + 1) : 0..<0
    }

    /// A position expressed relative to a page, so that it survives a change of scale or window width.
    public struct Anchor: Equatable {
        public var page: Int
        /// Across the page: 0 at its left edge, 1 at its right edge. Outside that range in the side margins.
        public var x: CGFloat
        /// Down the page: 0 at its top edge, 1 at its bottom edge. Always within that range.
        public var y: CGFloat
        /// How far past the page the position lies, in points on screen: positive in the gap below it,
        /// negative above the first page. Kept in points because gaps do not grow with the scale.
        public var overshoot: CGFloat

        public init(page: Int, x: CGFloat = 0, y: CGFloat = 0, overshoot: CGFloat = 0) {
            self.page = page
            self.x = x
            self.y = y
            self.overshoot = overshoot
        }
    }

    public func anchor(at point: CGPoint) -> Anchor? {
        guard let page = pageIndex(atY: point.y) else { return nil }
        let frame = frames[page]
        let x = frame.width > 0 ? (point.x - frame.minX) / frame.width : 0
        if point.y < frame.minY { return Anchor(page: page, x: x, y: 0, overshoot: point.y - frame.minY) }
        if point.y > frame.maxY { return Anchor(page: page, x: x, y: 1, overshoot: point.y - frame.maxY) }
        return Anchor(page: page, x: x, y: frame.height > 0 ? (point.y - frame.minY) / frame.height : 0)
    }

    public func point(for anchor: Anchor) -> CGPoint {
        guard !frames.isEmpty else { return .zero }
        let frame = frames[min(max(anchor.page, 0), frames.count - 1)]
        return CGPoint(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height + anchor.overshoot)
    }
}

public enum Zoom {
    /// The range the zoom buttons and the pinch gesture move within.
    public static let minimum: CGFloat = 0.25
    public static let maximum: CGFloat = 8
    /// Fit-width may go this far below `minimum` to make a very wide page fit a narrow window.
    public static let fitMinimum: CGFloat = 0.05
    /// Each press of zoom in or zoom out changes the scale by this factor.
    public static let step: CGFloat = 1.25

    public static func clamped(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minimum), maximum)
    }
}
