import AppKit
import LumaCore

/// The app's own tab strip: one entry per open document, painted directly.
///
/// The system's window tabs are not used because each of them keeps a whole window's worth of
/// picture in memory (see ADR 0001). Where the tabs sit and what a click means is worked out by
/// `TabStripLayout`; this view only paints and forwards.
final class TabStripView: NSView {
    static let height: CGFloat = 30

    var titles: [String] = [] { didSet { settle() } }
    var selectedIndex = 0 { didSet { reveal(selectedIndex) } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }
    private var scrollOffset: CGFloat = 0

    override var isFlipped: Bool { true }

    private var layout: TabStripLayout {
        TabStripLayout(count: titles.count, width: bounds.width, height: bounds.height, scrollOffset: scrollOffset)
    }

    /// Tabs on which the close box is showing, and therefore clickable.
    private var closeBoxShowing: Set<Int> {
        var showing: Set<Int> = [selectedIndex]
        if let hoveredIndex { showing.insert(hoveredIndex) }
        return showing
    }

    private func settle() {
        scrollOffset = layout.scrollOffset
        needsDisplay = true
    }

    private func reveal(_ index: Int) {
        scrollOffset = layout.scrollOffset(revealing: index)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reveal(selectedIndex)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let layout = self.layout
        let showing = closeBoxShowing
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = .center
        for (index, title) in titles.enumerated() {
            let frame = layout.tabFrame(index)
            guard frame.intersects(bounds) else { continue }
            let selected = index == selectedIndex
            if selected {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 4), xRadius: 6, yRadius: 6).fill()
            }
            if showing.contains(index) {
                let box = layout.closeBox(index).insetBy(dx: 4.5, dy: 4.5)
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: box.minX, y: box.minY))
                cross.line(to: NSPoint(x: box.maxX, y: box.maxY))
                cross.move(to: NSPoint(x: box.maxX, y: box.minY))
                cross.line(to: NSPoint(x: box.minX, y: box.maxY))
                cross.lineWidth = 1.2
                NSColor.secondaryLabelColor.setStroke()
                cross.stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular),
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let textFrame = NSRect(x: frame.minX + 28, y: (frame.height - 16) / 2, width: max(0, frame.width - 40), height: 16)
            (title as NSString).draw(in: textFrame, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        switch layout.hit(at: convert(event.locationInWindow, from: nil), closeBoxShowingOn: closeBoxShowing) {
        case .select(let index): onSelect?(index)
        case .close(let index): onClose?(index)
        case .nothing: break
        }
    }

    /// With more tabs than fit, the strip scrolls sideways.
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollOffset = TabStripLayout(count: titles.count, width: bounds.width, height: bounds.height,
                                      scrollOffset: scrollOffset - delta).scrollOffset
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func hovered(_ event: NSEvent) -> Int? {
        switch layout.hit(at: convert(event.locationInWindow, from: nil), closeBoxShowingOn: []) {
        case .select(let index): return index
        default: return nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = hovered(event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }
}
