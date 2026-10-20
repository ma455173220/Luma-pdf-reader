import AppKit
import LumaCore
import PDFKit

/// The scrolling surface the pages are painted on.
///
/// It paints whatever strip AppKit asks for, straight from the PDF, and stores nothing.
final class PageCanvasView: NSView, NSMenuItemValidation {
    private(set) var document: PDFDocument?
    private(set) var layout = PageLayout(pageSizes: [], scale: 1, viewportWidth: 0)
    /// Matches of the current search, marked on the pages.
    var searchResults = SearchResults() { didSet { needsDisplay = true } }
    /// The text the reader has selected, shown with the system's selection colour.
    var selection: PDFSelection? {
        didSet {
            placeSelectionOverlay()
            if selection != nil { onSelect?() }
        }
    }
    /// Told when text is selected in the page.
    var onSelect: (() -> Void)?
    /// The selection is shown on a small view of its own above the pages, so that selecting text
    /// never repaints the pages themselves. Repainting them for every move of a drag left a second
    /// window-sized picture alive for good (about 34 MB on the reference window).
    private let selectionOverlay = SelectionOverlayView()

    private func placeSelectionOverlay() {
        let rects = selectionRects(selection)
        guard let first = rects.first else {
            selectionOverlay.isHidden = true
            return
        }
        let area = rects.dropFirst().reduce(first) { $0.union($1) }.integral
        if selectionOverlay.superview == nil { addSubview(selectionOverlay) }
        selectionOverlay.frame = area
        selectionOverlay.rects = rects.map { $0.offsetBy(dx: -area.minX, dy: -area.minY) }
        selectionOverlay.isHidden = false
    }

    /// The selection's lines, on the canvas.
    private func selectionRects(_ selection: PDFSelection?) -> [CGRect] {
        guard let selection, let document else { return [] }
        var rects: [CGRect] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                guard index != NSNotFound, layout.frames.indices.contains(index) else { continue }
                let rect = line.bounds(for: page)
                if rect.width > 0, rect.height > 0 { rects.append(PageGeometry.canvasRect(forPageRect: rect, pageFrame: layout.frames[index], page: page)) }
            }
        }
        return rects
    }

    /// Pinch gesture: the change in magnification and where the fingers are, in this view's coordinates.
    var onMagnify: ((CGFloat, NSPoint) -> Void)?
    /// The pointer moved to this point of the canvas, or left it (nil).
    var onPointer: ((NSPoint?) -> Void)?
    /// The mouse button went down, moved while held, and came up, at these points of the canvas.
    /// Each returns true if something acted on it. The second value of `onMouseDown` is the click count.
    var onMouseDown: ((NSPoint, Int) -> Bool)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    /// The selected text, if any: cleaned up for pasting (⌘C), or exactly as the PDF has it (⌥⌘C).
    var selectedText: ((_ cleaned: Bool) -> String?)?
    /// The Escape key. Returns true if something acted on it.
    var onEscape: (() -> Bool)?
    /// A click with the right mouse button (or a two-finger tap, or a click with Control held).
    /// Returns true if something acted on it.
    var onSecondaryClick: (() -> Bool)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(_ document: PDFDocument?, layout: PageLayout) {
        self.document = document
        self.layout = layout
        setFrameSize(layout.contentSize)
        needsDisplay = true
        placeSelectionOverlay()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        dirtyRect.fill()
        guard let document, let context = NSGraphicsContext.current?.cgContext else { return }
        // The strip is widened by a point so that a page's hairline is repainted along with it.
        for index in layout.pages(intersecting: dirtyRect.insetBy(dx: 0, dy: -1)) {
            guard let page = document.page(at: index) else { continue }
            let frame = layout.frames[index]
            PageRenderer.draw(page, in: frame, context: context)
            Theme.pageEdge.setStroke()
            let edge = NSBezierPath(rect: frame.insetBy(dx: -0.25, dy: -0.25))
            edge.lineWidth = 0.5
            edge.stroke()
            paintSearchMatches(onPage: index, page: page, frame: frame, context: context)
            paintNoteMarkers(onPage: page, frame: frame)
        }
    }

    /// Where the note sign of a mark goes: just past the end of its first line, a little raised, so it
    /// sits in the margin or the gap between columns rather than on the text.
    func noteSignRect(for annotation: PDFAnnotation, pageFrame frame: CGRect, page: PDFPage) -> CGRect {
        let box = PageGeometry.canvasRect(forPageRect: annotation.bounds, pageFrame: frame, page: page)
        let size = min(28, max(18, 11 * layout.scale))
        // Kept on the page, so that it is drawn whole and can be clicked even near the page's edges.
        let x = min(box.maxX + 3, frame.maxX - size)
        let y = max(box.minY - size * 0.5, frame.minY)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// The mark whose note sign is under a point of the canvas, if any.
    func markWithNoteSign(at point: NSPoint) -> PDFAnnotation? {
        guard let document, let index = layout.pageIndex(atY: point.y), let page = document.page(at: index) else { return nil }
        let frame = layout.frames[index]
        return page.annotations.last { annotation in
            MarkupEditor.isMark(annotation) && !(annotation.contents ?? "").isEmpty
                && noteSignRect(for: annotation, pageFrame: frame, page: page).insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    /// A speech bubble beside every highlight or underline that carries a note: filled with the
    /// mark's colour, outlined and lined in a deeper shade of it, so it shows on white and on colour.
    private func paintNoteMarkers(onPage page: PDFPage, frame: CGRect) {
        for annotation in page.annotations where MarkupEditor.isMark(annotation) && !(annotation.contents ?? "").isEmpty {
            let rect = noteSignRect(for: annotation, pageFrame: frame, page: page)
            let fill = annotation.color.usingColorSpace(.sRGB) ?? annotation.color
            let ink = fill.blended(withFraction: 0.6, of: .black) ?? .darkGray
            // The bubble's body, then its tail at the bottom left. The canvas is measured from the top.
            let body = rect.insetBy(dx: rect.width * 0.06, dy: 0)
            let bodyRect = CGRect(x: body.minX, y: body.minY + body.height * 0.08, width: body.width, height: body.height * 0.66)
            let bubble = NSBezierPath(roundedRect: bodyRect, xRadius: bodyRect.height * 0.25, yRadius: bodyRect.height * 0.25)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: bodyRect.minX + bodyRect.width * 0.22, y: bodyRect.maxY - 0.5))
            tail.line(to: NSPoint(x: bodyRect.minX + bodyRect.width * 0.18, y: rect.maxY - rect.height * 0.04))
            tail.line(to: NSPoint(x: bodyRect.minX + bodyRect.width * 0.48, y: bodyRect.maxY - 0.5))
            tail.close()
            bubble.append(tail)
            fill.setFill()
            bubble.fill()
            ink.setStroke()
            bubble.lineWidth = max(1, rect.width / 16)
            bubble.lineJoinStyle = .round
            bubble.stroke()
            // Two lines of "writing" inside.
            let lines = NSBezierPath()
            for (fraction, length) in [(0.38, 0.62), (0.62, 0.42)] {
                let y = bodyRect.minY + bodyRect.height * fraction
                lines.move(to: NSPoint(x: bodyRect.minX + bodyRect.width * 0.2, y: y))
                lines.line(to: NSPoint(x: bodyRect.minX + bodyRect.width * (0.2 + length), y: y))
            }
            lines.lineWidth = max(1, rect.width / 14)
            lines.lineCapStyle = .round
            lines.stroke()
        }
    }

    /// Marks the search matches on a page: all of them lightly, the one the reader is on strongly.
    /// Multiplying the colour into the page keeps the text underneath readable.
    private func paintSearchMatches(onPage index: Int, page: PDFPage, frame: CGRect, context: CGContext) {
        let rects = searchResults.rects(onPage: index)
        guard !rects.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setFillColor(Theme.searchMatch.cgColor)
        for rect in rects {
            context.fill(PageGeometry.canvasRect(forPageRect: rect, pageFrame: frame, page: page).insetBy(dx: -1, dy: -1))
        }
        if let current = searchResults.currentMatch, current.page == index {
            context.setFillColor(Theme.currentSearchMatch.cgColor)
            for rect in current.rects {
                context.fill(PageGeometry.canvasRect(forPageRect: rect, pageFrame: frame, page: page).insetBy(dx: -1, dy: -1))
            }
        }
        context.restoreGState()
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification, convert(event.locationInWindow, from: nil))
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onPointer?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A click with Control held is the keyboard's way of making a right click.
        if event.modifierFlags.contains(.control), onSecondaryClick?() == true { return }
        if onMouseDown?(convert(event.locationInWindow, from: nil), event.clickCount) != true { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        // Dragging past the edge of the view scrolls it, so a selection can run on to the next page.
        autoscroll(with: event)
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }

    @objc func copy(_ sender: Any?) { putOnClipboard(cleaned: true) }

    @objc func copyOriginalText(_ sender: Any?) { putOnClipboard(cleaned: false) }

    private func putOnClipboard(cleaned: Bool) {
        guard let text = selectedText?(cleaned), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) || menuItem.action == #selector(copyOriginalText(_:)) {
            return !(selectedText?(false) ?? "").isEmpty
        }
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        if onSecondaryClick?() != true { super.rightMouseDown(with: event) }
    }

    // MARK: Keyboard scrolling

    override func keyDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return super.keyDown(with: event) }
        let viewport = scroll.contentView.bounds
        let line: CGFloat = 48
        let screenful = max(viewport.height - line, line)
        switch event.keyCode {
        case 125: scrollVertically(by: line)                                                     // ↓
        case 126: scrollVertically(by: -line)                                                    // ↑
        case 49: scrollVertically(by: event.modifierFlags.contains(.shift) ? -screenful : screenful)  // space
        case 121: scrollVertically(by: screenful)                                                // page down
        case 116: scrollVertically(by: -screenful)                                               // page up
        case 115: scrollVertically(by: -.greatestFiniteMagnitude)                                // home
        case 119: scrollVertically(by: .greatestFiniteMagnitude)                                 // end
        case 53: if onEscape?() != true { super.keyDown(with: event) }                           // esc
        default: super.keyDown(with: event)
        }
    }

    private func scrollVertically(by distance: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let highest = max(0, frame.height - clip.bounds.height)
        let target = min(max(clip.bounds.minY + distance, 0), highest)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scroll.reflectScrolledClipView(clip)
    }
}

/// The selected lines, painted in the system's selection colour over the page.
private final class SelectionOverlayView: NSView {
    var rects: [CGRect] = [] { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Multiplied into the page underneath, as a highlighter would be, so the text stays black.
        layer?.compositingFilter = "multiplyBlendMode"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // Clicks and drags go to the page beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.7).setFill()
        rects.forEach { $0.fill() }
    }
}
