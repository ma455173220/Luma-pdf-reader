import AppKit
import LumaCore
import PDFKit

/// What the reader can do to pages from the thumbnails: turn or take out one (right-click), move
/// one (drag it), insert another PDF's pages (drop the file between two thumbnails). A file dropped
/// anywhere else on the thumbnails opens in a tab of its own, as it does elsewhere in the window.
struct ThumbnailActions {
    var turn: (Int, _ clockwise: Bool) -> Void = { _, _ in }
    var takeOut: (Int) -> Void = { _ in }
    var move: (Int, _ toGap: Int) -> Void = { _, _ in }
    var insert: ([URL], _ atGap: Int) -> Void = { _, _ in }
    var open: ([URL]) -> Void = { _ in }
    var canTakeOut: () -> Bool = { false }
}

/// The surface the thumbnails are painted on. Like the main canvas it paints straight from the PDF
/// and keeps no images: only the thumbnails in view are ever painted.
private final class ThumbnailCanvas: NSView {
    var document: PDFDocument?
    var layout = PageLayout(pageSizes: [], scale: 1, viewportWidth: 0)
    var currentPage = 0
    var onSelect: ((Int) -> Void)?
    var actions = ThumbnailActions()

    /// The gap a page being dragged, or a file, would go into; drawn as a line.
    private var insertionGap: Int? {
        didSet { if insertionGap != oldValue { needsDisplay = true } }
    }
    /// The page pressed, and where, until it is dragged far enough to count as moving it.
    private var press: (index: Int, at: NSPoint)?
    private var isMoving = false
    /// While a page is moved: a lifted copy of its thumbnail that follows the pointer, made once from
    /// the page when the drag starts and let go when it ends.
    private var floating: NSImageView?
    /// Where in the thumbnail it was picked up, so that it stays under the pointer at the same spot.
    private var grip = CGSize.zero
    private static let liftedScale: CGFloat = 0.92

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        dirtyRect.fill()
        guard let document, let context = NSGraphicsContext.current?.cgContext else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        // The page number sits in the gap under its thumbnail, so a strip that only touches the gap repaints it too.
        for index in layout.pages(intersecting: dirtyRect.insetBy(dx: 0, dy: -PageLayout.gap)) {
            guard let page = document.page(at: index) else { continue }
            let frame = layout.frames[index]
            PageRenderer.draw(page, in: frame, context: context)
            if isMoving, index == press?.index {
                // The page being moved leaves a faint trace of itself in its old place.
                Theme.canvas.withAlphaComponent(0.7).setFill()
                frame.fill(using: .sourceOver)
            }
            let isCurrent = index == currentPage
            (isCurrent ? NSColor.controlAccentColor : Theme.pageEdge).setStroke()
            let edge = NSBezierPath(rect: frame.insetBy(dx: isCurrent ? -1 : -0.25, dy: isCurrent ? -1 : -0.25))
            edge.lineWidth = isCurrent ? 2 : 0.5
            edge.stroke()
            ("\(index + 1)" as NSString).draw(in: NSRect(x: frame.minX, y: frame.maxY + 1, width: frame.width, height: PageLayout.gap - 1), withAttributes: labelAttributes)
        }
        if let gap = insertionGap, let line = insertionLine(gap) {
            // A bar with a ring at its start, the way the system marks where something will go.
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2).fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: line.minX - 7, y: line.midY - 4, width: 8, height: 8))
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            Theme.canvas.setFill()
            ring.fill()
            ring.stroke()
        }
    }

    /// Where the line for a gap is drawn: just above the thumbnail after it, or below the last.
    private func insertionLine(_ gap: Int) -> NSRect? {
        guard let last = layout.frames.last else { return nil }
        let y = gap < layout.frames.count ? layout.frames[gap].minY - 2.5 : last.maxY + PageLayout.gap - 2.5
        let x = layout.frames.map(\.minX).min() ?? 0
        let width = layout.frames.map(\.maxX).max().map { $0 - x } ?? 0
        return NSRect(x: x, y: y - 1.5, width: width + 4, height: 3)
    }

    /// The gap at a height: before page i, or after the last. Near the top or bottom quarter of a
    /// thumbnail, or between two, it is the gap there. Over the middle of a thumbnail there is none,
    /// unless `anywhere`, when the nearer gap is taken.
    private func gap(atY y: CGFloat, anywhere: Bool) -> Int? {
        guard let index = layout.pageIndex(atY: y) else { return nil }
        let frame = layout.frames[index]
        if y < frame.minY { return index }
        if y >= frame.maxY { return index + 1 }
        let edge = frame.height * 0.25
        if y < frame.minY + edge { return index }
        if y > frame.maxY - edge { return index + 1 }
        return anywhere ? (y < frame.midY ? index : index + 1) : nil
    }

    func debugDropGap(atY y: CGFloat) -> Int? { gap(atY: y, anywhere: false) }

    /// In a walk-through: where thumbnail `index` is, in window coordinates.
    func debugFrame(_ index: Int) -> NSRect? {
        layout.frames.indices.contains(index) ? convert(layout.frames[index], to: nil) : nil
    }

    private func thumbnail(at point: NSPoint) -> Int? {
        guard let index = layout.pageIndex(atY: point.y), layout.frames[index].insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return index
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = thumbnail(at: point) else { return }
        press = (index, point)
        isMoving = false
        onSelect?(index)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !isMoving && hypot(point.x - press.at.x, point.y - press.at.y) < 5 { return }
        if !isMoving { lift(press.index, at: press.at) }
        isMoving = true
        autoscroll(with: event)
        follow(point)
        // Dragged out of the column sideways: no line, and letting go there moves nothing.
        insertionGap = isBesideColumn(point) ? nil : gap(atY: point.y, anywhere: true)
    }

    private func isBesideColumn(_ point: NSPoint) -> Bool {
        point.x < visibleRect.minX || point.x > visibleRect.maxX
    }

    /// Picks the page up: a copy of its thumbnail, a little smaller and with a shadow, over the column.
    private func lift(_ index: Int, at point: NSPoint) {
        guard layout.frames.indices.contains(index), let page = document?.page(at: index) else { return }
        let frame = layout.frames[index]
        let image = NSImage(size: frame.size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            PageRenderer.draw(page, in: rect, context: context)
            return true
        }
        let view = NSImageView(frame: NSRect(origin: .zero, size: NSSize(width: frame.width * Self.liftedScale, height: frame.height * Self.liftedScale)))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 1.5
        view.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            return shadow
        }()
        // See-through enough that the insertion mark under it still shows.
        view.alphaValue = 0.8
        grip = CGSize(width: (point.x - frame.minX) * Self.liftedScale, height: (point.y - frame.minY) * Self.liftedScale)
        addSubview(view)
        floating = view
        setNeedsDisplay(frame.insetBy(dx: -3, dy: -3))
    }

    private func follow(_ point: NSPoint) {
        floating?.setFrameOrigin(NSPoint(x: point.x - grip.width, y: point.y - grip.height))
    }

    private func putDown() {
        floating?.removeFromSuperview()
        floating = nil
    }

    var debugIsFloating: Bool { floating != nil }

    override func mouseUp(with event: NSEvent) {
        defer {
            if let index = press?.index, layout.frames.indices.contains(index) { setNeedsDisplay(layout.frames[index].insetBy(dx: -3, dy: -3)) }
            press = nil
            isMoving = false
            insertionGap = nil
            putDown()
        }
        guard let press, isMoving, let gap = insertionGap, !isBesideColumn(convert(event.locationInWindow, from: nil)) else { return }
        // Dropped back where it was: nothing moves.
        if gap == press.index || gap == press.index + 1 { return }
        actions.move(press.index, gap)
    }

    /// In a walk-through: drags a thumbnail to a gap with mouse events, as a hand would.
    /// In a walk-through: picks a thumbnail up and drags it over a gap, without letting go.
    func debugPickUp(_ index: Int, overGap gap: Int) {
        guard layout.frames.indices.contains(index), let window else { return }
        let start = NSPoint(x: layout.frames[index].midX, y: layout.frames[index].midY)
        let endY = gap < layout.frames.count ? layout.frames[gap].minY - 2 : (layout.frames.last?.maxY ?? 0) + PageLayout.gap / 2
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, start) { mouseDown(with: down) }
        for step in 1...8 {
            if let drag = event(.leftMouseDragged, NSPoint(x: start.x + 10, y: start.y + (endY - start.y) * CGFloat(step) / 8)) { mouseDragged(with: drag) }
        }
        debugHeldAt = NSPoint(x: start.x + 10, y: endY)
    }

    private var debugHeldAt: NSPoint?

    /// In a walk-through: lets go of what debugPickUp picked up.
    func debugLetGo() {
        guard let point = debugHeldAt, let window else { return }
        debugHeldAt = nil
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { mouseUp(with: up) }
    }

    /// In a walk-through: drags a thumbnail out of the column sideways and lets go there.
    func debugDragOut(_ index: Int) {
        guard layout.frames.indices.contains(index), let window else { return }
        let start = NSPoint(x: layout.frames[index].midX, y: layout.frames[index].midY)
        let outside = NSPoint(x: visibleRect.maxX + 80, y: start.y + 40)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, start) { mouseDown(with: down) }
        if let drag = event(.leftMouseDragged, outside) { mouseDragged(with: drag) }
        if let up = event(.leftMouseUp, outside) { mouseUp(with: up) }
    }

    func debugDrag(_ index: Int, toGap gap: Int) {
        guard layout.frames.indices.contains(index), let window else { return }
        let start = NSPoint(x: layout.frames[index].midX, y: layout.frames[index].midY)
        let endY = gap < layout.frames.count ? layout.frames[gap].minY - 2 : (layout.frames.last?.maxY ?? 0) + PageLayout.gap / 2
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = event(.leftMouseDown, start) { mouseDown(with: down) }
        for step in 1...8 {
            let y = start.y + (endY - start.y) * CGFloat(step) / 8
            if let drag = event(.leftMouseDragged, NSPoint(x: start.x, y: y)) { mouseDragged(with: drag) }
        }
        if let up = event(.leftMouseUp, NSPoint(x: start.x, y: endY)) { mouseUp(with: up) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = thumbnail(at: point) else { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ enabled: Bool = true, _ work: @escaping () -> Void) {
            let entry = NSMenuItem(title: title, action: enabled ? #selector(MenuAction.run(_:)) : nil, keyEquivalent: "")
            let action = MenuAction(work)
            entry.target = action
            entry.representedObject = action
            menu.addItem(entry)
        }
        item(L("Rotate Right")) { [weak self] in self?.actions.turn(index, true) }
        item(L("Rotate Left")) { [weak self] in self?.actions.turn(index, false) }
        menu.addItem(.separator())
        item(L("Delete This Page"), actions.canTakeOut()) { [weak self] in self?.actions.takeOut(index) }
        return menu
    }

    // MARK: Files dropped on the thumbnails

    private func pdfURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["com.adobe.pdf"],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !pdfURLs(sender).isEmpty else { return [] }
        insertionGap = gap(atY: convert(sender.draggingLocation, from: nil).y, anywhere: false)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { insertionGap = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = pdfURLs(sender)
        let gap = insertionGap
        insertionGap = nil
        guard !urls.isEmpty else { return false }
        // Handled after the drop has finished, so that a question asked meanwhile does not hold it up.
        DispatchQueue.main.async { [actions] in
            if let gap { actions.insert(urls, gap) } else { actions.open(urls) }
        }
        return true
    }
}

/// A menu item's work, kept alive by the item.
private final class MenuAction: NSObject {
    private let work: () -> Void
    init(_ work: @escaping () -> Void) { self.work = work }
    @objc func run(_ sender: Any?) { work() }
}

/// A column of page thumbnails. Clicking one goes to that page; the pages can be edited from here.
final class ThumbnailListView: NSView {
    var onSelect: ((Int) -> Void)? {
        didSet { canvas.onSelect = onSelect }
    }
    var actions: ThumbnailActions {
        get { canvas.actions }
        set { canvas.actions = newValue }
    }

    private let scrollView = NSScrollView()
    private let canvas = ThumbnailCanvas()
    private var pageSizes: [CGSize] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.canvas
        scrollView.documentView = canvas
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    func show(_ document: PDFDocument?, pageSizes: [CGSize], currentPage: Int) {
        canvas.document = document
        canvas.currentPage = currentPage
        self.pageSizes = pageSizes
        relayout()
        reveal(currentPage)
    }

    func debugDrag(_ index: Int, toGap gap: Int) { canvas.debugDrag(index, toGap: gap) }
    func debugDragOut(_ index: Int) { canvas.debugDragOut(index) }
    /// For tests: the gap a file dropped at a height of the thumbnails would go into, if any.
    func debugDropGap(atY y: CGFloat) -> Int? { canvas.debugDropGap(atY: y) }
    var debugCanvasHeight: CGFloat { canvas.frame.height }
    var debugIsFloating: Bool { canvas.debugIsFloating }
    func debugPickUp(_ index: Int, overGap gap: Int) { canvas.debugPickUp(index, overGap: gap) }
    func debugLetGo() { canvas.debugLetGo() }
    func debugFrame(_ index: Int) -> NSRect? { canvas.debugFrame(index) }

    /// The same file read afresh (ADR 0006): its new document painted in the old one's place, laid out
    /// and scrolled as it was. The thumbnails are painted on demand, so nothing else changes.
    func documentReadAfresh(_ document: PDFDocument) {
        canvas.document = document
        canvas.needsDisplay = true
    }

    /// After a page edit: the same document laid out again, staying where the reader had scrolled to.
    func pagesChanged(pageSizes: [CGSize], currentPage: Int) {
        self.pageSizes = pageSizes
        canvas.currentPage = currentPage
        let clip = scrollView.contentView
        let top = clip.bounds.minY
        relayout()
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, top), max(0, canvas.frame.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
    }

    private func relayout() {
        let width = scrollView.contentView.bounds.width
        let scale = PageLayout.fitWidthScale(pageSizes: pageSizes, viewportWidth: width)
        canvas.layout = PageLayout(pageSizes: pageSizes, scale: scale, viewportWidth: width)
        // At least as tall as the column, so that a file dropped in the space below the last
        // thumbnail is taken there (appended), not opened in a tab of its own.
        let content = canvas.layout.contentSize
        canvas.setFrameSize(NSSize(width: content.width, height: max(content.height, scrollView.contentView.bounds.height)))
        canvas.needsDisplay = true
    }

    /// Marks the page the reader is on and keeps its thumbnail in view.
    func setCurrentPage(_ page: Int) {
        guard page != canvas.currentPage else { return }
        let old = canvas.currentPage
        canvas.currentPage = page
        for index in [old, page] where canvas.layout.frames.indices.contains(index) {
            canvas.setNeedsDisplay(canvas.layout.frames[index].insetBy(dx: -3, dy: -3))
        }
        reveal(page)
    }

    private func reveal(_ page: Int) {
        guard canvas.layout.frames.indices.contains(page) else { return }
        let frame = canvas.layout.frames[page].insetBy(dx: 0, dy: -PageLayout.gap)
        let clip = scrollView.contentView
        guard !clip.bounds.contains(frame) else { return }
        let highest = max(0, canvas.frame.height - clip.bounds.height)
        let target = frame.minY < clip.bounds.minY ? frame.minY : frame.maxY - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: min(max(target, 0), highest)))
        scrollView.reflectScrolledClipView(clip)
    }
}
