import AppKit
import LumaCore
import PDFKit

/// How a preview's page can be made larger or smaller: from the whole page just fitting in the
/// preview to four times as large as the page fitting its width (初值, ADR 0005). Measured in the
/// page's size as shown at scale 1.
struct PreviewZoom {
    static let mostTimesWidth: CGFloat = 4

    /// The scales the page can be drawn at in a preview of `view`; never shutting out `start`, the
    /// scale it opened at.
    static func range(page: CGSize, view: CGSize, start: CGFloat) -> ClosedRange<CGFloat> {
        guard page.width > 0, page.height > 0 else { return start...start }
        let whole = min(view.width / page.width, view.height / page.height)
        let most = max(mostTimesWidth * view.width / page.width, start, whole)
        return whole...most
    }

    /// The top-left of the part in view, kept on the page: a page smaller than the view, along
    /// either side, is centred along it.
    static func kept(_ offset: CGPoint, drawn: CGSize, view: CGSize) -> CGPoint {
        func along(_ value: CGFloat, _ drawn: CGFloat, _ view: CGFloat) -> CGFloat {
            drawn <= view ? -(view - drawn) / 2 : min(max(value, 0), drawn - view)
        }
        return CGPoint(x: along(offset.x, drawn.width, view.width), y: along(offset.y, drawn.height, view.height))
    }

    /// The scale and the part in view after zooming by `factor` around `point` of the view: the spot
    /// of the page under that point stays under it.
    static func zoomed(scale: CGFloat, offset: CGPoint, by factor: CGFloat, around point: CGPoint,
                       page: CGSize, view: CGSize, range: ClosedRange<CGFloat>) -> (scale: CGFloat, offset: CGPoint) {
        let new = min(max(scale * factor, range.lowerBound), range.upperBound)
        let spot = CGPoint(x: (point.x + offset.x) / scale, y: (point.y + offset.y) / scale)
        let moved = CGPoint(x: spot.x * new - point.x, y: spot.y * new - point.y)
        return (new, kept(moved, drawn: CGSize(width: page.width * new, height: page.height * new), view: view))
    }
}

/// The page as seen through the preview: only the part in view is ever painted, so a preview holds
/// no more than one preview-sized picture however large the page is drawn (a column of a two-column
/// page is drawn at more than twice the size, and the reader can zoom in four times further).
private final class PreviewPageView: NSView {
    private let page: PDFPage
    private(set) var scale: CGFloat
    /// The scale the preview opened at, which zooming always allows back.
    private let startScale: CGFloat
    /// The top-left of the part of the page in view, in the page as drawn; negative along a side
    /// where the page is smaller than the view, which centres it.
    private var offset: CGPoint
    /// Text selected, in the page's own coordinates.
    var selected: [CGRect] = [] { didSet { needsDisplay = true } }

    init(frame: NSRect, page: PDFPage, plan: PreviewGeometry.Plan) {
        self.page = page
        self.scale = plan.scale
        self.startScale = plan.scale
        self.offset = CGPoint(x: plan.scrollX, y: plan.scrollY)
        super.init(frame: frame)
    }

    /// The page at scale 1, measured afresh each time, since a pinned preview stays while its page
    /// is turned, and a turned page is shown the other way round.
    private var shown: CGSize { PageRenderer.displaySize(of: page) }
    private var drawn: CGSize { CGSize(width: shown.width * scale, height: shown.height * scale) }
    private var range: ClosedRange<CGFloat> { PreviewZoom.range(page: shown, view: bounds.size, start: startScale) }

    var debugDrawnSize: CGSize { drawn }
    var debugRange: ClosedRange<CGFloat> { range }

    /// Keeps the scale within what the preview allows and the part in view on the page, after the
    /// page or the preview changed size.
    private func keep() {
        scale = min(max(scale, range.lowerBound), range.upperBound)
        offset = PreviewZoom.kept(offset, drawn: drawn, view: bounds.size)
        changed()
    }

    /// Told after every zoom or move, for the scroll bars.
    var onChange: (() -> Void)?

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    /// The page as drawn, the part in view, and the view: what the scroll bars show.
    var placing: (drawn: CGSize, offset: CGPoint, view: CGSize) { (drawn, offset, bounds.size) }

    /// Moves the part in view to an offset along one side or both (from a scroll bar).
    func move(x: CGFloat? = nil, y: CGFloat? = nil) {
        offset = PreviewZoom.kept(CGPoint(x: x ?? offset.x, y: y ?? offset.y), drawn: drawn, view: bounds.size)
        changed()
    }

    func pageChanged() { keep() }

    func zoom(by factor: CGFloat, around point: CGPoint) {
        (scale, offset) = PreviewZoom.zoomed(scale: scale, offset: offset, by: factor, around: point, page: shown, view: bounds.size, range: range)
        changed()
    }

    /// Moves the page under the view: by the trackpad, or held and dragged.
    func pan(by delta: CGSize) {
        offset = PreviewZoom.kept(CGPoint(x: offset.x - delta.width, y: offset.y - delta.height), drawn: drawn, view: bounds.size)
        changed()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Around a page zoomed out smaller than the preview: grey, so that the page's edge shows.
        NSColor(white: 0.9, alpha: 1).setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = drawn
        PageRenderer.draw(page, in: CGRect(x: -offset.x, y: -offset.y, width: size.width, height: size.height), context: context)
        // A selection in the system's selection colour, over the page as a highlighter would be.
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).setFill()
        for rect in selected { inView(rect).insetBy(dx: -1, dy: -0.5).fill(using: .multiply) }
    }

    /// A rectangle of the page's own coordinates, where it is in the view.
    private func inView(_ rect: CGRect) -> CGRect {
        let shown = PageGeometry.displayRect(forPageRect: rect, on: page)
        return CGRect(x: shown.minX * scale - offset.x, y: shown.minY * scale - offset.y, width: shown.width * scale, height: shown.height * scale)
    }

    /// The place on the page, in its own coordinates, under a point of the view.
    func pagePoint(at point: CGPoint) -> CGPoint {
        PageGeometry.pagePoint(forDisplayPoint: CGPoint(x: (point.x + offset.x) / scale, y: (point.y + offset.y) / scale), on: page)
    }

    /// The edges of the preview being dragged, while they are.
    var resizing: PreviewPopupView.Edges = []

    /// Made larger or smaller (a pinned preview's edge dragged): the page stays at the same scale and
    /// where it was on the screen, as in a window, so that only the dragged edge shows more or less of
    /// it. The line the link leads to, near the top, stays in view when the bottom is dragged up.
    override func setFrameSize(_ newSize: NSSize) {
        let old = bounds.size
        super.setFrameSize(newSize)
        guard old.width > 0, old.height > 0 else { return }
        if resizing.contains(.left) { offset.x += old.width - newSize.width }
        if resizing.contains(.top) { offset.y += old.height - newSize.height }
        // Too small for the larger preview now (or too large for the smaller): zoomed around the
        // corner that stays put.
        let allowed = min(max(scale, range.lowerBound), range.upperBound)
        let still = CGPoint(x: resizing.contains(.left) ? newSize.width : 0, y: resizing.contains(.top) ? newSize.height : 0)
        if allowed != scale { zoom(by: allowed / scale, around: still) } else { keep() }
    }

    var debugOffset: CGPoint { offset }
}

/// Marks in a pinned preview's corner, showing that it can be made larger or smaller. Only a picture:
/// the preview itself decides where the pointer resizes and what the pointer looks like.
private final class ResizeGrip: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        for k in 1...3 {
            let path = NSBezierPath()
            let d = CGFloat(k) * 4
            path.move(to: NSPoint(x: bounds.maxX - d, y: bounds.maxY - 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.maxY - d))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// The strip along a pinned preview's top, which it is dragged about by. Only a picture.
private final class TitleStrip: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.82).setFill()
        bounds.fill()
        NSColor.black.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
        // A short bar in the middle, saying it can be held.
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.midY - 2, width: 36, height: 4), xRadius: 2, yRadius: 2).fill()
    }
}

/// The inside of a hover preview: the page a link leads to, already scrolled to the spot it names.
/// The reader moves it with the wheel or the trackpad, or by holding and dragging, and zooms it with
/// ⌘ and the wheel or by pinching. Everything it holds goes away with it.
///
/// A pin in its corner keeps it: pinned, it stays put when the pointer leaves, can be dragged about
/// by a strip along its top and made larger or smaller by its edges and corners, and has a cross in
/// the corner instead to close it (ADR 0005).
final class PreviewPopupView: NSView {
    /// Told when the pointer enters or leaves the preview.
    var onHover: ((Bool) -> Void)?
    /// Told when the pin is pressed; and, once pinned, when the cross is.
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var isPinned = false
    private let pinButton = NSButton()
    private let pageView: PreviewPageView
    /// For a preview of a reference: its lines, for the two buttons beside the pin, which copy it and
    /// look it up in Google Scholar. Joined into text only when a button is pressed (joining may ask
    /// the system's spelling dictionary, which then stays loaded).
    private let reference: [PreviewText.Line]?
    private let copyButton = NSButton()
    private let searchButton = NSButton()
    /// The page shown, from the session's reading document, for its text: selecting and copying
    /// read it there, not from the document shown (ADR 0006). Nil when it cannot be read.
    private let textPage: (() -> PDFPage?)?
    /// Text selected in the preview: each line's text and where it is, kept as they are rather than
    /// as a selection of the reading document, which may have been let go of and opened again since.
    private var selectedLines: [PreviewText.Line] = []
    /// The page's lines of text, read once, for telling text from the space around it.
    private var textLines: [PreviewText.Line]?
    /// Told when text is selected in the preview, so that ⌘C in the page copies it (the page keeps
    /// the keyboard).
    var onSelect: (() -> Void)?

    /// What a press on the preview took hold of, and where the pointer was then, in the window.
    private enum Hold {
        /// The page, to move it under the view.
        case page(last: NSPoint)
        /// A pinned preview by its strip, to move it about; its frame then.
        case strip(from: NSPoint, frame: CGRect)
        /// A pinned preview by its edges, to resize it; its frame then.
        case edges(Edges, from: NSPoint, frame: CGRect)
        /// Text, to select it; where on the page the press was.
        case text(from: CGPoint)
    }
    private var hold: Hold?

    static let stripHeight: CGFloat = 28

    /// The system's scroll bars, shown along the right and the bottom whenever the page is larger
    /// than the preview that way, so that it is plain there is more to see; hidden when it all fits.
    private let verticalBar = NSScroller(frame: NSRect(x: 0, y: 0, width: 20, height: 100))
    private let horizontalBar = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    private var bars: [NSScroller] { [verticalBar, horizontalBar] }

    /// `reference`: the lines of the reference the link leads to, if it is one; `textPage`: the page
    /// for its text.
    init(frame: NSRect, page: PDFPage, plan: PreviewGeometry.Plan, reference: [PreviewText.Line]? = nil,
         textPage: (() -> PDFPage?)? = nil) {
        pageView = PreviewPageView(frame: NSRect(origin: .zero, size: frame.size), page: page, plan: plan)
        self.reference = reference
        self.textPage = textPage
        super.init(frame: frame)
        pageView.autoresizingMask = [.width, .height]
        addSubview(pageView)

        pinButton.bezelStyle = .circular
        pinButton.isBordered = false
        pinButton.wantsLayer = true
        pinButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        pinButton.layer?.cornerRadius = 11
        pinButton.frame = NSRect(x: bounds.width - 38, y: 3, width: 22, height: 22)
        pinButton.autoresizingMask = [.minXMargin]
        pinButton.target = self
        pinButton.action = #selector(pinPressed)
        showPinState()
        addSubview(pinButton)

        if reference != nil {
            for (button, symbol, tip, action, k) in [(copyButton, "doc.on.doc", L("Copy this reference"), #selector(copyReference), 1),
                                                    (searchButton, "magnifyingglass", L("Search Google Scholar for this reference"), #selector(searchReference), 2)] {
                button.bezelStyle = .circular
                button.isBordered = false
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
                button.layer?.cornerRadius = 11
                button.frame = NSRect(x: bounds.width - 38 - CGFloat(k) * 26, y: 3, width: 22, height: 22)
                button.autoresizingMask = [.minXMargin]
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
                button.toolTip = tip
                button.target = self
                button.action = action
                addSubview(button)
            }
        }

        for bar in bars {
            bar.scrollerStyle = .legacy
            bar.knobStyle = .dark
            bar.controlSize = .small
            bar.isEnabled = true
            bar.target = self
            bar.action = #selector(barMoved(_:))
            addSubview(bar)
        }
        pageView.onChange = { [weak self] in self?.placeBars() }
        placeBars()
    }

    /// Lays out and sets the scroll bars from the part of the page in view. They keep clear of the
    /// strip along the top, of the outermost points along the edges and of the corners, which resize
    /// a pinned preview.
    private func placeBars() {
        let (drawn, offset, view) = pageView.placing
        let width = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        let edge = PreviewPopupView.edgeBand, corner = PreviewPopupView.cornerBand
        let across = drawn.width > view.width + 0.5, down = drawn.height > view.height + 0.5
        verticalBar.isHidden = !down
        horizontalBar.isHidden = !across
        let top = PreviewPopupView.stripHeight
        verticalBar.frame = NSRect(x: bounds.width - edge - width, y: top, width: width,
                                   height: max(0, bounds.height - top - corner - (across ? width : 0)))
        horizontalBar.frame = NSRect(x: corner, y: bounds.height - edge - width,
                                     width: max(0, bounds.width - 2 * corner - (down ? width : 0)), height: width)
        if down {
            verticalBar.knobProportion = view.height / drawn.height
            verticalBar.doubleValue = Double(offset.y / (drawn.height - view.height))
        }
        if across {
            horizontalBar.knobProportion = view.width / drawn.width
            horizontalBar.doubleValue = Double(offset.x / (drawn.width - view.width))
        }
    }

    @objc private func barMoved(_ bar: NSScroller) {
        let (drawn, offset, view) = pageView.placing
        let vertical = bar === verticalBar
        let length = vertical ? view.height : view.width, room = (vertical ? drawn.height : drawn.width) - length
        var value = vertical ? offset.y : offset.x
        switch bar.hitPart {
        case .decrementPage: value -= length * 0.9
        case .incrementPage: value += length * 0.9
        default: value = CGFloat(bar.doubleValue) * room
        }
        if vertical { pageView.move(y: value) } else { pageView.move(x: value) }
    }

    /// For tests: which scroll bars show, and where the vertical one's knob is (0 at the top).
    var debugBars: (vertical: Bool, horizontal: Bool, verticalValue: Double) {
        (!verticalBar.isHidden, !horizontalBar.isHidden, verticalBar.doubleValue)
    }

    private func showPinState() {
        let (symbol, tip) = isPinned ? ("xmark", L("Close")) : ("pin", L("Pin: stays open when the pointer leaves; drag the top strip to move it, an edge or corner to resize it"))
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        pinButton.toolTip = tip
    }

    @objc private func pinPressed() {
        if isPinned { onClose?() } else { onPin?() }
    }

    /// The reference's text, without its number in front.
    var referenceText: String? {
        reference.map { PreviewText.withoutNumber(PreviewPopupView.cleaned($0, page: 0)) }
    }

    @objc private func copyReference() {
        guard let text = referenceText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func searchReference() {
        guard let text = referenceText, let url = PreviewPopupView.scholarSearch(text) else { return }
        // A walk-through must not open the reader's browser.
        if Benchmark.isRequested { print("  (Google Scholar not opened in a walk-through)") } else { NSWorkspace.shared.open(url) }
    }

    /// The Google Scholar search for a reference's text. 知白 itself does not go online: the browser does.
    static func scholarSearch(_ reference: String) -> URL? {
        // "+" and "&" in the text are escaped too: in a query "+" would be read as a space.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        guard let query = String(reference.prefix(300)).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://scholar.google.com/scholar?q=" + query)
    }

    /// Lines of a page's text joined as copying joins them (ADR 0003's clean copy), without running
    /// heads: a preview shows a single page.
    static func cleaned(_ lines: [PreviewText.Line], page: Int) -> String {
        CleanCopy.text(from: lines.map { CleanCopy.Line(text: $0.text, frame: $0.rect, page: page) }, isWord: ReaderWindowController.isEnglishWord)
    }

    var debugHasReferenceButtons: Bool { copyButton.superview != nil }

    // MARK: Selecting text

    /// Whether there is text under a point of the view: on a line of text or in the narrow space
    /// between two, so that the pointer does not flicker between I-beam and hand across a paragraph.
    private func isOverText(_ point: CGPoint) -> Bool {
        // No page to read text from (pages edited and not yet saved): no text to select here.
        guard let page = textPage?() else {
            textLines = nil
            return false
        }
        if textLines == nil { textLines = PreviewText.lines(of: page) }
        let onPage = pageView.pagePoint(at: point)
        return textLines?.contains { $0.rect.insetBy(dx: -2, dy: -3).contains(onPage) } ?? false
    }

    private func select(from start: CGPoint, to end: CGPoint) {
        guard let page = textPage?() else { return }
        keep(page.selection(from: start, to: pageView.pagePoint(at: end)), on: page)
    }

    /// Keeps a selection's lines as text and places, not the selection itself.
    private func keep(_ selection: PDFSelection?, on page: PDFPage) {
        selectedLines = selection?.selectionsByLine().compactMap { line -> PreviewText.Line? in
            guard let text = line.string, !text.isEmpty else { return nil }
            return PreviewText.Line(text: text, rect: line.bounds(for: page))
        } ?? []
        pageView.selected = selectedLines.map(\.rect)
        if !selectedLines.isEmpty { onSelect?() }
    }

    func clearSelection() {
        selectedLines = []
        pageView.selected = []
    }

    /// The text selected, joined as copying in the page joins it (the clean copy); nil when none.
    /// ⌘C in the page copies it (see LinkInteractionController.previewSelectedText).
    var selectedText: String? {
        selectedLines.isEmpty ? nil : PreviewPopupView.cleaned(selectedLines, page: 0)
    }

    /// The text selected, line by line as the page has it (for 复制原文).
    var rawSelectedText: String? {
        selectedLines.isEmpty ? nil : selectedLines.map(\.text).joined(separator: "\n")
    }

    /// For tests: selects as dragging from one point of the view to another would, and the text ⌘C
    /// would copy (the pasteboard itself is left alone).
    func debugSelect(from start: CGPoint, to end: CGPoint) -> String? {
        select(from: pageView.pagePoint(at: start), to: end)
        return selectedText
    }

    /// For tests: the size the page is drawn at now, and the scales it can be zoomed between.
    var debugDrawnSize: CGSize { pageView.debugDrawnSize }
    var debugZoomRange: ClosedRange<CGFloat> { pageView.debugRange }
    var debugScale: CGFloat { pageView.scale }
    var debugOffset: CGPoint { pageView.debugOffset }
    /// For tests: resizes the preview as dragging these edges would.
    func debugResize(to size: CGSize, by edges: Edges) {
        pageView.resizing = edges
        setFrameSize(size)
        pageView.resizing = []
    }
    func debugZoom(by factor: CGFloat) { pageView.zoom(by: factor, around: CGPoint(x: bounds.midX, y: bounds.midY)) }

    /// After its page was edited (turned): drawn again the right way round.
    func pageChanged() { pageView.pageChanged() }

    // MARK: Zooming and moving the page

    /// The mouse wheel and the trackpad's two fingers move the page, as everywhere on the Mac; held
    /// with ⌘ they zoom around the pointer instead. Pinching zooms too.
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.modifierFlags.contains(.command) else {
            // A wheel counts in lines, the trackpad in points.
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            return pageView.pan(by: CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step))
        }
        // Rolled away from the reader zooms in, whichever way the system turns scrolling.
        let away = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        let perStep: CGFloat = event.hasPreciseScrollingDeltas ? 1.01 : 1.15
        pageView.zoom(by: min(max(pow(perStep, away), 0.5), 2), around: point)
    }

    override func magnify(with event: NSEvent) {
        pageView.zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    // MARK: Pinned: moving and resizing

    /// How small and how large a pinned preview can be made (初值, ADR 0005). The largest is also
    /// kept within the window.
    static let smallest = CGSize(width: 260, height: 160)
    static let largest = CGSize(width: 1400, height: 1000)

    /// The most area a pinned preview can take on a screen of this many pixels to the point, so that
    /// it holds no more than about 15 MB beyond a hover preview's (ADR 0005): measured at about 40
    /// bytes a square point on a Retina screen, a quarter of that at one pixel to the point.
    static func largestArea(scale: CGFloat) -> CGFloat {
        580_000 * 4 / max(1, scale * scale)
    }

    /// A size made no larger than `area`, by taking off from the sides being dragged (both at a
    /// corner, in proportion), never below the smallest.
    static func within(area: CGFloat, _ size: CGSize, across: Bool, down: Bool) -> CGSize {
        guard size.width * size.height > area else { return size }
        var fitted = size
        switch (across, down) {
        case (true, false): fitted.width = area / size.height
        case (false, true): fitted.height = area / size.width
        default:
            let k = (area / (size.width * size.height)).squareRoot()
            fitted = CGSize(width: size.width * k, height: size.height * k)
        }
        return CGSize(width: max(fitted.width, smallest.width), height: max(fitted.height, smallest.height))
    }

    /// The size a pinned preview takes when its corner is dragged by `delta` from `start`, within the
    /// limits and within `room`.
    static func resized(_ start: CGSize, by delta: CGSize, room: CGSize, area: CGFloat = .infinity) -> CGSize {
        let most = CGSize(width: max(smallest.width, min(largest.width, room.width)), height: max(smallest.height, min(largest.height, room.height)))
        let size = CGSize(width: min(max(start.width + delta.width, smallest.width), most.width),
                          height: min(max(start.height + delta.height, smallest.height), most.height))
        return within(area: area, size, across: delta.width != 0, down: delta.height != 0)
    }

    /// The edges of a pinned preview a point is near, as for a window: within a band along each edge,
    /// wider at the corners so that a corner is easy to catch. Empty further in.
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    static let edgeBand: CGFloat = 5
    static let cornerBand: CGFloat = 18

    /// Which edges a point in a preview of `size` (measured from its top-left) is near.
    static func edges(at point: CGPoint, in size: CGSize) -> Edges {
        let x = point.x, y = point.y
        let left = x < cornerBand, right = x > size.width - cornerBand
        let top = y < cornerBand, bottom = y > size.height - cornerBand
        if (left || right) && (top || bottom) { return [left ? .left : .right, top ? .top : .bottom] }
        var near: Edges = []
        if x < edgeBand { near.insert(.left) } else if x > size.width - edgeBand { near.insert(.right) }
        if y < edgeBand { near.insert(.top) } else if y > size.height - edgeBand { near.insert(.bottom) }
        return near
    }

    /// The frame after dragging `edges` by `delta` (measured right and down), the other edges staying
    /// where they were; within the size limits, and within `container` less a margin.
    static func resizedFrame(_ start: CGRect, edges: Edges, by delta: CGSize, within container: CGRect, margin: CGFloat = 8,
                             area: CGFloat = .infinity) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) {
            minX = min(max(start.minX + delta.width, container.minX + margin, start.maxX - largest.width), start.maxX - smallest.width)
        } else if edges.contains(.right) {
            maxX = max(min(start.maxX + delta.width, container.maxX - margin, start.minX + largest.width), start.minX + smallest.width)
        }
        if edges.contains(.top) {
            minY = min(max(start.minY + delta.height, container.minY + margin, start.maxY - largest.height), start.maxY - smallest.height)
        } else if edges.contains(.bottom) {
            maxY = max(min(start.maxY + delta.height, container.maxY - margin, start.minY + largest.height), start.minY + smallest.height)
        }
        // Too large an area: taken off the dragged sides, the others staying put.
        let size = within(area: area, CGSize(width: maxX - minX, height: maxY - minY),
                          across: !edges.isDisjoint(with: [.left, .right]), down: !edges.isDisjoint(with: [.top, .bottom]))
        if edges.contains(.left) { minX = maxX - size.width } else { maxX = minX + size.width }
        if edges.contains(.top) { minY = maxY - size.height } else { maxY = minY + size.height }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// What a press at a point of the preview takes hold of, before it starts.
    private enum Place { case button, bar, page, strip, edges(Edges) }

    private func place(at point: CGPoint) -> Place {
        if [pinButton, copyButton, searchButton].contains(where: { $0.superview === self && $0.frame.contains(point) }) { return .button }
        if bars.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return .bar }
        guard isPinned else { return .page }
        let near = PreviewPopupView.edges(at: point, in: bounds.size)
        if !near.isEmpty { return .edges(near) }
        return point.y < PreviewPopupView.stripHeight ? .strip : .page
    }

    /// The pointer for a place in the preview: a double arrow to resize by the edges and corners of a
    /// pinned one, an arrow over its button and its strip, a hand over the page (closed while held).
    /// Decided here alone, so that no two pointers take turns while it is over the preview.
    private func cursor(for place: Place) -> NSCursor {
        switch place {
        case .button, .bar, .strip: return .arrow
        case .page:
            if case .text? = hold { return .iBeam }
            return hold == nil ? .openHand : .closedHand
        case .edges(let near):
            let position: NSCursor.FrameResizePosition
            switch (near.contains(.left), near.contains(.right), near.contains(.top), near.contains(.bottom)) {
            case (true, _, true, _): position = .topLeft
            case (_, true, true, _): position = .topRight
            case (true, _, _, true): position = .bottomLeft
            case (_, true, _, true): position = .bottomRight
            case (true, _, _, _): position = .left
            case (_, true, _, _): position = .right
            case (_, _, true, _): position = .top
            default: position = .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
    }

    private func showCursor(for event: NSEvent) {
        // While something is held the pointer keeps the look it took then, wherever it has got to.
        guard hold == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let place = place(at: point)
        // Over text, an I-beam: a press there selects it.
        if case .page = place, isOverText(point) { return NSCursor.iBeam.set() }
        cursor(for: place).set()
    }

    override func cursorUpdate(with event: NSEvent) { showCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { showCursor(for: event) }

    /// Keeps the preview: the pin becomes a cross; the preview can be dragged about by a strip along
    /// its top, and made larger or smaller by its edges and corners.
    func pin() {
        isPinned = true
        showPinState()
        let strip = TitleStrip(frame: NSRect(x: 0, y: 0, width: bounds.width, height: PreviewPopupView.stripHeight))
        strip.autoresizingMask = [.width]
        addSubview(strip, positioned: .above, relativeTo: pageView)
        let grip = ResizeGrip(frame: NSRect(x: bounds.width - 16, y: bounds.height - 16, width: 16, height: 16))
        grip.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(grip)
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
        placeBars()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Every press but on the buttons and the scroll bars belongs to the preview itself, which works
        // out what it took hold of; so do the wheel and the trackpad.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        switch place(at: local) {
        case .button, .bar: return super.hitTest(point)
        default: return self
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frame = superview?.frame ?? .zero
        switch place(at: point) {
        case .button, .bar: return
        case .page:
            // On text a press selects it; elsewhere it takes hold of the page, to move it.
            // The page keeps the keyboard: ⌘C there copies what is selected here.
            if isOverText(point) {
                let start = pageView.pagePoint(at: point)
                hold = .text(from: start)
                clearSelection()
                if event.clickCount >= 2, let page = textPage?() {
                    // A double click selects the word, a triple the line.
                    keep(event.clickCount == 2 ? page.selectionForWord(at: start) : page.selectionForLine(at: start), on: page)
                }
                NSCursor.iBeam.set()
                return
            }
            clearSelection()
            hold = .page(last: event.locationInWindow)
        case .strip: hold = .strip(from: event.locationInWindow, frame: frame)
        case .edges(let near): hold = .edges(near, from: event.locationInWindow, frame: frame)
        }
        cursor(for: place(at: point)).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let hold, let panel = superview, let host = panel.superview else { return }
        // The window measures up from the bottom; the host and the page measure down from the top.
        func down(_ from: NSPoint) -> CGSize {
            CGSize(width: event.locationInWindow.x - from.x, height: from.y - event.locationInWindow.y)
        }
        switch hold {
        case .page(let last):
            pageView.pan(by: down(last))
            self.hold = .page(last: event.locationInWindow)
        case .text(let from):
            select(from: from, to: convert(event.locationInWindow, from: nil))
        case .strip(let from, let frame):
            let delta = down(from)
            var origin = NSPoint(x: frame.minX + delta.width, y: frame.minY + (host.isFlipped ? delta.height : -delta.height))
            origin.x = min(max(origin.x, host.bounds.minX - panel.frame.width + 60), host.bounds.maxX - 60)
            origin.y = min(max(origin.y, host.bounds.minY), host.bounds.maxY - 30)
            panel.setFrameOrigin(origin)
        case .edges(let near, let from, let frame):
            let delta = down(from)
            pageView.resizing = near
            panel.frame = PreviewPopupView.resizedFrame(frame, edges: near, by: CGSize(width: delta.width, height: host.isFlipped ? delta.height : -delta.height),
                                                        within: host.bounds, area: PreviewPopupView.largestArea(scale: window?.backingScaleFactor ?? 2))
            pageView.resizing = []
        }
    }

    override func mouseUp(with event: NSEvent) {
        hold = nil
        showCursor(for: event)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
