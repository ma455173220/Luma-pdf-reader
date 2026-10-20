import CoreGraphics
import Foundation

/// Decides when a hover preview appears and disappears. Pure logic: it is told what the pointer is
/// over and what time it is, and answers with what to do.
///
/// The preview appears after the pointer has rested on a link for a moment, and goes away shortly
/// after the pointer has left both the link and the preview. The short wait on leaving is what lets
/// the pointer travel from the link into the preview to scroll it.
public struct HoverPreviewState<Target: Equatable> {
    public enum Action: Equatable {
        case none
        case show(Target)
        case hide
    }

    public var showDelay: TimeInterval = 0.4
    public var hideGrace: TimeInterval = 0.25

    private enum Phase: Equatable {
        case idle
        case waiting(Target, since: TimeInterval)
        case showing(Target, leftAt: TimeInterval?)
    }

    private var phase: Phase = .idle

    public init() {}

    public var shown: Target? {
        if case .showing(let target, _) = phase { return target }
        return nil
    }

    /// The moment at which `timeReached` should next be called, if any.
    public var deadline: TimeInterval? {
        switch phase {
        case .idle: return nil
        case .waiting(_, let since): return since + showDelay
        case .showing(_, let leftAt): return leftAt.map { $0 + hideGrace }
        }
    }

    /// Call when the pointer moves, or when it enters or leaves the preview.
    public mutating func pointer(over target: Target?, insidePreview: Bool, at time: TimeInterval) {
        switch phase {
        case .idle:
            if let target { phase = .waiting(target, since: time) }
        case .waiting(let current, _):
            if target == nil {
                phase = .idle
            } else if let target, target != current {
                phase = .waiting(target, since: time)
            }
        case .showing(let current, let leftAt):
            if insidePreview || target == current {
                phase = .showing(current, leftAt: nil)
            } else if leftAt == nil {
                phase = .showing(current, leftAt: time)
            }
        }
    }

    /// Call when `deadline` has passed.
    public mutating func timeReached(_ time: TimeInterval) -> Action {
        switch phase {
        case .waiting(let target, let since) where time >= since + showDelay:
            phase = .showing(target, leftAt: nil)
            return .show(target)
        case .showing(_, let leftAt?) where time >= leftAt + hideGrace:
            phase = .idle
            return .hide
        default:
            return .none
        }
    }

    /// Ends whatever is going on at once: the view scrolled, the tab changed, something was clicked.
    public mutating func dismiss() -> Action {
        defer { phase = .idle }
        if case .showing = phase { return .hide }
        return .none
    }
}

/// Sizes and positions for the hover preview. Coordinates have y growing downward.
public enum PreviewGeometry {
    public struct Plan: Equatable {
        /// The scale at which the target page is painted inside the preview.
        public var scale: CGFloat
        /// The painted page's size, which is what can be scrolled through.
        public var pageSize: CGSize
        /// How far down the preview starts scrolled.
        public var scrollY: CGFloat
        /// How far across it starts scrolled: more than 0 only when it shows one column of the page.
        public var scrollX: CGFloat = 0
    }

    /// The same, showing only one column of the page, as wide as the preview: for a two-column page,
    /// where the whole page width would make the words half the size. `column` is the column's left
    /// and right edges on the page as shown, at scale 1.
    public static func plan(pageDisplaySize: CGSize, destinationFromTop: CGFloat?, previewSize: CGSize, column: ClosedRange<CGFloat>,
                            topMargin: CGFloat = 8, sideMargin: CGFloat = 6) -> Plan {
        let width = column.upperBound - column.lowerBound
        guard pageDisplaySize.width > 0, pageDisplaySize.height > 0, previewSize.width > 2 * sideMargin, width > 20 else {
            return plan(pageDisplaySize: pageDisplaySize, destinationFromTop: destinationFromTop, previewSize: previewSize, topMargin: topMargin)
        }
        let scale = min(max((previewSize.width - 2 * sideMargin) / width, Zoom.fitMinimum), Zoom.maximum)
        let pageSize = CGSize(width: pageDisplaySize.width * scale, height: pageDisplaySize.height * scale)
        let furthestDown = max(0, pageSize.height - previewSize.height)
        let wanted = (destinationFromTop ?? 0) * scale - topMargin
        let furthestAcross = max(0, pageSize.width - previewSize.width)
        let across = min(max(column.lowerBound * scale - sideMargin, 0), furthestAcross)
        return Plan(scale: scale, pageSize: pageSize, scrollY: min(max(wanted, 0), furthestDown), scrollX: across)
    }

    /// The target page is shown as wide as the preview, starting just above the spot the link leads to.
    /// - Parameter destinationFromTop: how far below the page's top edge that spot is, at scale 1; nil for the top of the page.
    public static func plan(pageDisplaySize: CGSize, destinationFromTop: CGFloat?, previewSize: CGSize, topMargin: CGFloat = 8) -> Plan {
        guard pageDisplaySize.width > 0, pageDisplaySize.height > 0, previewSize.width > 0 else {
            return Plan(scale: 1, pageSize: .zero, scrollY: 0)
        }
        let scale = min(max(previewSize.width / pageDisplaySize.width, Zoom.fitMinimum), Zoom.maximum)
        let pageSize = CGSize(width: pageDisplaySize.width * scale, height: pageDisplaySize.height * scale)
        let furthest = max(0, pageSize.height - previewSize.height)
        let wanted = (destinationFromTop ?? 0) * scale - topMargin
        return Plan(scale: scale, pageSize: pageSize, scrollY: min(max(wanted, 0), furthest))
    }

    /// The size the preview takes inside a viewport: its usual size, or less in a small window.
    public static func previewSize(in viewport: CGSize, usual: CGSize = CGSize(width: 640, height: 380), margin: CGFloat = 8) -> CGSize {
        CGSize(width: max(0, min(usual.width, viewport.width - 2 * margin)), height: max(0, min(usual.height, viewport.height / 2)))
    }

    /// Where the preview goes: under the link when there is room, above it otherwise, and never outside the container.
    public static func frame(forPreviewOfSize size: CGSize, near link: CGRect, in container: CGRect, gap: CGFloat = 6, margin: CGFloat = 8) -> CGRect {
        let roomBelow = container.maxY - margin - (link.maxY + gap)
        let roomAbove = (link.minY - gap) - (container.minY + margin)
        let below = roomBelow >= size.height || roomBelow >= roomAbove
        var y = below ? link.maxY + gap : link.minY - gap - size.height
        y = min(max(y, container.minY + margin), max(container.minY + margin, container.maxY - margin - size.height))
        var x = link.midX - size.width / 2
        x = min(max(x, container.minX + margin), max(container.minX + margin, container.maxX - margin - size.width))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Tells a two-column page from a single-column one by its lines of text, and gives the column a
/// point is in.
public enum PageColumns {
    /// The left and right edges of the column `x` is in, or nil when the page is not plainly set in
    /// two columns. `lines` are the page's lines of text, `width` the page's width, all in the same
    /// coordinates.
    ///
    /// Two columns: many lines keep to each half of the page, and few run across its middle (a title,
    /// a wide figure caption). Then the column is as wide as the lines on that side.
    public static func column(containing x: CGFloat, lines: [CGRect], pageMinX: CGFloat = 0, width: CGFloat) -> ClosedRange<CGFloat>? {
        guard width > 0 else { return nil }
        let middle = pageMinX + width / 2
        let slack = width * 0.03
        let text = lines.filter { $0.width > width * 0.08 && $0.height > 0 }
        let left = text.filter { $0.maxX <= middle + slack }
        let right = text.filter { $0.minX >= middle - slack }
        let across = text.filter { $0.minX < middle - slack && $0.maxX > middle + slack }
        guard left.count >= 5, right.count >= 5, Double(across.count) <= 0.2 * Double(left.count + right.count) else { return nil }
        let side = x < middle ? left : right
        guard let low = side.map(\.minX).min(), let high = side.map(\.maxX).max(), high > low else { return nil }
        return low...high
    }
}
