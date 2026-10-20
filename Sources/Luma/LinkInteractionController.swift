import AppKit
import LumaCore
import PDFKit

/// Everything that happens when the pointer meets a link on the page: the pointing-hand cursor,
/// the hover preview, and following the link on a click.
final class LinkInteractionController {
    private weak var host: NSView?
    private weak var scrollView: NSScrollView?
    private weak var canvas: PageCanvasView?

    var session: DocumentSession? {
        didSet {
            dismiss()
            columnLines = [:]
            showPinnedIfItBelongs()
        }
    }
    /// Off while the magnifier is on: the two would fight over the pointer.
    var isEnabled = true { didSet { if !isEnabled { dismiss() } } }
    /// Asked to go to a place in the document: a page, and optionally a point on it in page coordinates.
    var onFollow: ((Int, CGPoint?) -> Void)?

    /// A link being hovered: where it is, and where it leads.
    private struct Hover: Equatable {
        let page: Int
        let rect: CGRect
        let targetPage: Int
        let targetPoint: CGPoint?
        /// For a reference to a figure or table worked out from the text: which one, so that the
        /// preview can mark its caption.
        var figure: FigureLabel? = nil
    }

    struct FigureLabel: Equatable {
        let kind: FigureKind
        let number: Int
    }

    private var state = HoverPreviewState<Hover>()
    /// The pale box behind the link under the pointer, the same for a document's own links and for
    /// those worked out from its citations. Only there while the pointer is.
    private var box: LinkHoverBox?
    private var timer: Timer?
    private var popup: FloatingPanelView?
    /// The hover being previewed in `popup`, for pinning it.
    private var popupHover: Hover?
    private var pointerInsidePopup = false
    /// The one pinned preview, and the document it belongs to (by file, so that it survives the tab
    /// sleeping and waking). Only one at a time: pinning another closes it (ADR 0005). It is taken
    /// off the window while another tab is in front, and put back when this one is.
    private var pinned: (panel: FloatingPanelView, file: URL)?
    /// Set by the benchmark's walk-through so that the real pointer, wherever it happens to be,
    /// does not close the preview before its picture is taken.
    private var isHeldForWalkThrough = false

    init(host: NSView, scrollView: NSScrollView, canvas: PageCanvasView) {
        self.host = host
        self.scrollView = scrollView
        self.canvas = canvas
    }

    var isShowingPreview: Bool { popup != nil }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The link under a point of the canvas, the page it is on, and, for a reference to a figure or
    /// table worked out from the text, which one.
    func link(at point: NSPoint) -> (link: PageLink, page: Int, figure: FigureLabel?)? {
        guard let session, let canvas, let index = canvas.layout.pageIndex(atY: point.y),
              canvas.layout.frames[index].contains(point), let page = session.document.page(at: index) else { return nil }
        let onPage = PageGeometry.pagePoint(forCanvasPoint: point, pageFrame: canvas.layout.frames[index], page: page)
        guard let found = PageLinks.link(at: onPage, in: session.links(onPage: index)),
              let link = session.resolved(found, onPage: index) else { return nil }
        var figure: FigureLabel?
        if case .figure(let kind, let number, _) = found.target { figure = FigureLabel(kind: kind, number: number) }
        return (link, index, figure)
    }

    /// Whether there is text under a point of the canvas, so that the cursor can show it can be selected.
    private func isOverText(_ point: NSPoint) -> Bool {
        guard let session, let canvas, let index = canvas.layout.pageIndex(atY: point.y),
              canvas.layout.frames[index].contains(point), let page = session.document.page(at: index) else { return false }
        return page.characterIndex(at: PageGeometry.pagePoint(forCanvasPoint: point, pageFrame: canvas.layout.frames[index], page: page)) >= 0
    }

    /// Where the pointer is now, in canvas coordinates; nil when it is not over the visible part of the canvas.
    private func pointerOnCanvas() -> NSPoint? {
        guard let canvas, let window = canvas.window else { return nil }
        let point = canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return canvas.visibleRect.contains(point) ? point : nil
    }

    func pointerMoved(to point: NSPoint?) {
        guard isEnabled, session != nil, !isHeldForWalkThrough else { return }
        // Over the pinned preview the page below is out of reach: the preview sets the pointer, and
        // no link under it is boxed or previewed.
        if let point, isUnderPinned(point) {
            showBox(around: nil)
            state.pointer(over: nil, insidePreview: pointerInsidePopup, at: now)
            schedule()
            return
        }
        var hover: Hover?
        var cursor = NSCursor.arrow
        var boxed: CGRect?
        if let point, let hit = link(at: point), let canvas, let page = session?.document.page(at: hit.page) {
            cursor = .pointingHand
            boxed = PageGeometry.canvasRect(forPageRect: hit.link.rect, pageFrame: canvas.layout.frames[hit.page], page: page)
            if case .place(let page, let target) = hit.link.target {
                hover = Hover(page: hit.page, rect: hit.link.rect, targetPage: page, targetPoint: target, figure: hit.figure)
            }
        } else if let point, isOverText(point) {
            cursor = .iBeam
        }
        if !pointerInsidePopup { cursor.set() }
        showBox(around: pointerInsidePopup ? nil : boxed)
        state.pointer(over: hover, insidePreview: pointerInsidePopup, at: now)
        schedule()
    }

    private func showBox(around rect: CGRect?) {
        guard let rect, let canvas else {
            box?.removeFromSuperview()
            box = nil
            return
        }
        let frame = rect.insetBy(dx: -0.5, dy: -0.5)
        if box == nil {
            let view = LinkHoverBox(frame: frame)
            canvas.addSubview(view)
            box = view
        }
        box?.frame = frame
    }

    /// Returns true if the click landed on a link and was dealt with.
    func clicked(at point: NSPoint) -> Bool {
        dismiss()
        guard isEnabled, let hit = link(at: point) else { return false }
        switch hit.link.target {
        case .place(let page, let target): onFollow?(page, target)
        case .web(let url):
            // A walk-through must not open the reader's browser or mail program.
            if Benchmark.isRequested { print("  (web link not opened in a walk-through: \(url.scheme ?? "?"))") } else { NSWorkspace.shared.open(url) }
        case .figure:
            break   // resolved by link(at:) before it gets here
        }
        return true
    }

    /// The page moved under the pointer. A preview belongs to where the link was, so it goes,
    /// unless the pointer is inside it (scrolling the preview itself).
    func viewScrolled() {
        guard isEnabled, !isHeldForWalkThrough else { return }
        if popup != nil && !pointerInsidePopup { dismiss() }
        pointerMoved(to: pointerOnCanvas())
    }

    func dismiss() {
        showBox(around: nil)
        isHeldForWalkThrough = false
        timer?.invalidate()
        timer = nil
        if state.dismiss() == .hide { hidePopup() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let deadline = state.deadline else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0, deadline - now) + 0.01, repeats: false) { [weak self] _ in
            self?.deadlineReached()
        }
    }

    private func deadlineReached() {
        switch state.timeReached(now) {
        case .show(let hover):
            show(hover)
        case .hide:
            hidePopup()
            // The pointer may by now be resting on another link without having moved since.
            pointerMoved(to: pointerOnCanvas())
        case .none:
            break
        }
        schedule()
    }

    private func show(_ hover: Hover) {
        hidePopup()
        guard let session, let host, let scrollView, let canvas, let source = session.document.page(at: hover.page),
              canvas.layout.frames.indices.contains(hover.page) else { return }
        let viewport = scrollView.frame
        let size = PreviewGeometry.previewSize(in: viewport.size)
        guard size.width > 80, size.height > 60 else { return }

        // Where the preview opens. A figure or table worked out from the text leads to its own start,
        // shown across the page. A document's own link is put right by what it is written as (ADR 0006):
        // a citation's entry found by its number, a figure's or table's caption by its label; the place
        // the link names alone may be well off, or say nothing of the column.
        var targetIndex = hover.targetPage
        var point = hover.targetPoint
        var inColumn = point.map { $0.x != session.document.page(at: hover.targetPage)?.bounds(for: .cropBox).minX } ?? false
        var reference: [PreviewText.Line]?
        if hover.figure != nil { inColumn = false }
        let lookupStarted = Date()
        session.textReader.previewShown()
        // LUMA_NO_TARGET_LOOKUP: a walk-through's comparison, opening on the place the link names alone.
        if ProcessInfo.processInfo.environment["LUMA_NO_TARGET_LOOKUP"] == nil,
           let reading = session.textReader.document, !session.pages.hasUnsavedChanges, let written = textPage(hover.page) {
            let text = PreviewTarget.linkText(hover.rect, on: written)
            if let found = PreviewTarget.find(text: text, page: hover.targetPage, point: point,
                                              in: reading, bodySize: session.bodySize, from: hover.page) {
                (targetIndex, point, inColumn) = (found.page, found.point, found.inColumn)
                if PreviewText.looksLikeReference(found.entry) { reference = found.entry }
                if Benchmark.isRequested, let first = found.entry.first {
                    print("  (entry found: \(found.entry.count) lines, \"\(first.text.prefix(40))\" … \"\(found.entry.last!.text.suffix(30))\")")
                }
            }
        }
        guard let target = session.document.page(at: targetIndex) else { return }
        let fromTop = point.map { PageGeometry.displayPoint(forPagePoint: $0, on: target).y }
        let displaySize = PageRenderer.displaySize(of: target)
        // On a two-column page, the column a citation's entry is in, as wide as the preview; else the
        // whole width. The reader zooms out from there to see the whole page.
        // The column widened to take in the target's own left edge: a list may set its numbers ("24.")
        // in a margin of their own, left of the column its text makes.
        let box = target.bounds(for: .cropBox)
        let shownColumn = (inColumn ? column(of: target, at: point) : nil).map { found -> ClosedRange<CGFloat> in
            guard let point else { return found }
            return min(found.lowerBound, max(0, point.x - box.minX - 4))...found.upperBound
        }
        let plan = shownColumn.map {
            PreviewGeometry.plan(pageDisplaySize: displaySize, destinationFromTop: fromTop, previewSize: size, column: $0)
        } ?? PreviewGeometry.plan(pageDisplaySize: displaySize, destinationFromTop: fromTop, previewSize: size)
        let linkOnCanvas = PageGeometry.canvasRect(forPageRect: hover.rect, pageFrame: canvas.layout.frames[hover.page], page: source)
        let frame = PreviewGeometry.frame(forPreviewOfSize: size, near: host.convert(linkOnCanvas, from: canvas), in: viewport)
        let lookupTime = Date().timeIntervalSince(lookupStarted)
        if Benchmark.isRequested {
            print(String(format: "  (looking up the target took %.1f ms)", lookupTime * 1000))
            print("  (preview of page \(targetIndex + 1) at \(point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "the top")\(inColumn ? ", its column" : ", the whole width")\(reference == nil ? "" : ", a reference"))")
        }
        let shownIndex = targetIndex
        let inside = PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: target, plan: plan, reference: reference,
                                      textPage: { [weak self] in self?.textPage(shownIndex) })
        inside.onHover = { [weak self] isInside in self?.pointerInPopupChanged(isInside) }
        inside.onSelect = { [weak self, weak inside] in
            guard let self, let inside else { return }
            if self.selectedPreview !== inside { self.selectedPreview?.clearSelection() }
            self.selectedPreview = inside
            self.onPreviewSelect?()
        }
        inside.onPin = { [weak self] in self?.pin() }
        let panel = FloatingPanelView(frame: frame, content: inside)
        host.addSubview(panel)
        popup = panel
        popupHover = hover
    }

    /// The column of an upright page that a point is in, measured from the page's left edge as shown;
    /// nil for a page in one column, a turned page, or no point to go by. Reads the page's lines of
    /// text, once per page while the document is shown.
    private func column(of page: PDFPage, at point: CGPoint?) -> ClosedRange<CGFloat>? {
        guard let point, page.rotation == 0, let session else { return nil }
        let index = session.document.index(for: page)
        let lines: [CGRect]
        if let known = columnLines[index] {
            lines = known
        } else {
            // Read from the session's reading document, so that the text read does not stay with the
            // document shown (ADR 0006).
            let reading = textPage(index) ?? page
            let box = reading.bounds(for: .cropBox)
            lines = reading.selection(for: box)?.selectionsByLine().map { $0.bounds(for: reading) } ?? []
            columnLines[index] = lines
        }
        let box = page.bounds(for: .cropBox)
        guard let column = PageColumns.column(containing: point.x, lines: lines, pageMinX: box.minX, width: box.width) else { return nil }
        return (column.lowerBound - box.minX)...(column.upperBound - box.minX)
    }

    /// The preview text was last selected in. The page keeps the keyboard, so ⌘C in the page copies
    /// what is selected there while it shows (ADR 0006).
    private weak var selectedPreview: PreviewPopupView?

    /// The text selected in a preview showing, if any: cleaned as copying joins it, or as it is.
    func previewSelectedText(cleaned: Bool) -> String? {
        guard let preview = selectedPreview, preview.window != nil else { return nil }
        return cleaned ? preview.selectedText : preview.rawSelectedText
    }

    /// Told when text is selected in a preview: the page should then have the keyboard, so that ⌘C
    /// reaches it even if a field (search, page number) had it.
    var onPreviewSelect: (() -> Void)?

    /// When text is selected in the page: none stays selected in a preview.
    func clearPreviewSelection() {
        selectedPreview?.clearSelection()
        selectedPreview = nil
    }

    /// A page of the session's reading document, for its text (ADR 0006); nil while pages are edited
    /// and not yet saved, when the file's pages are not the ones shown.
    private func textPage(_ index: Int) -> PDFPage? {
        guard let session, !session.pages.hasUnsavedChanges else { return nil }
        return session.textReader.page(at: index)
    }

    /// Each target page's lines of text, by page number, for finding its columns. Forgotten when
    /// another document is shown.
    private var columnLines: [Int: [CGRect]] = [:]

    /// The preview showing becomes the pinned one: it stays where it is, out of the hover's hands.
    private func pin() {
        guard let panel = popup, let session, let inside = panel.content as? PreviewPopupView else { return }
        unpin()
        isHeldForWalkThrough = false
        popup = nil
        popupHover = nil
        pointerInsidePopup = false
        timer?.invalidate()
        timer = nil
        _ = state.dismiss()
        inside.onHover = nil
        inside.onClose = { [weak self] in self?.unpin() }
        inside.pin()
        pinned = (panel, session.url)
    }

    /// Closes the pinned preview, whichever document it belongs to.
    func unpin() {
        pinned?.panel.removeFromSuperview()
        pinned = nil
    }

    /// After the tab in front changed: the pinned preview shows over its own document only.
    private func showPinnedIfItBelongs() {
        guard let pinned, let host else { return }
        let belongs = session.map { $0.url == pinned.file } ?? false
        if belongs && pinned.panel.superview == nil {
            host.addSubview(pinned.panel)
            // The window may have been made smaller while another tab was in front.
            pinned.panel.frame = fitted(pinned.panel.frame, in: host)
        } else if !belongs {
            pinned.panel.removeFromSuperview()
        }
    }

    /// When a tab is closed: its pinned preview goes for good.
    func documentClosed(_ file: URL) {
        if pinned?.file == file { unpin() }
    }

    var isShowingPinned: Bool { pinned?.panel.superview != nil }

    /// Whether a point of the canvas lies under the pinned preview showing.
    func isUnderPinned(_ point: NSPoint) -> Bool {
        guard let panel = pinned?.panel, let host = panel.superview, let canvas else { return false }
        return panel.frame.contains(host.convert(point, from: canvas))
    }

    /// Whether a point of the canvas lies under a preview showing, pinned or not: there the preview
    /// sets the pointer.
    func isUnderPreview(_ point: NSPoint) -> Bool {
        if isUnderPinned(point) { return true }
        guard let panel = popup, let host = panel.superview, let canvas else { return false }
        return panel.frame.contains(host.convert(point, from: canvas))
    }

    /// After the window changed size or screen: a pinned preview is brought back inside it, and within
    /// the area the screen allows.
    func containerResized() {
        guard let panel = pinned?.panel, let host, panel.superview != nil else { return }
        panel.frame = fitted(panel.frame, in: host)
    }

    /// A frame moved so that it lies within a container, made smaller first if it no longer fits
    /// (not below a pinned preview's smallest size); the top-left first.
    /// A pinned preview's frame kept inside the window and within the area its screen allows: one made
    /// large on a screen of one pixel to the point is made smaller when the window moves to a Retina
    /// screen (ADR 0005), its top-left staying put.
    private func fitted(_ frame: CGRect, in host: NSView) -> CGRect {
        let area = PreviewPopupView.largestArea(scale: host.window?.backingScaleFactor ?? 2)
        let size = PreviewPopupView.within(area: area, frame.size, across: true, down: true)
        return LinkInteractionController.keptInside(CGRect(origin: frame.origin, size: size), host.bounds)
    }

    static func keptInside(_ frame: CGRect, _ container: CGRect, margin: CGFloat = 8) -> CGRect {
        var moved = frame
        moved.size.width = max(min(frame.width, container.width - 2 * margin), min(frame.width, PreviewPopupView.smallest.width))
        moved.size.height = max(min(frame.height, container.height - 2 * margin), min(frame.height, PreviewPopupView.smallest.height))
        moved.origin.x = max(container.minX + margin, min(frame.minX, container.maxX - margin - moved.width))
        moved.origin.y = max(container.minY + margin, min(frame.minY, container.maxY - margin - moved.height))
        return moved
    }

    /// After a page edit: a pinned preview whose page was turned is drawn the right way round.
    func pagesChanged() {
        (pinned?.panel.content as? PreviewPopupView)?.pageChanged()
    }

    /// For the benchmark's walk-through: makes the pinned preview as large as it can be, as dragging
    /// its corner all the way would.
    func debugMakePinnedLargest() {
        guard let panel = pinned?.panel, let host else { return }
        // Moved to the window's top-left first, as a reader would to give it the most room.
        panel.setFrameOrigin(NSPoint(x: host.bounds.minX + 8, y: host.isFlipped ? host.bounds.minY + 8 : host.bounds.maxY - 8 - panel.frame.height))
        let room = CGSize(width: host.bounds.maxX - 8 - panel.frame.minX, height: host.bounds.maxY - 8 - panel.frame.minY)
        panel.setFrameSize(PreviewPopupView.resized(panel.frame.size, by: CGSize(width: 5000, height: 5000), room: room,
                                                    area: PreviewPopupView.largestArea(scale: host.window?.backingScaleFactor ?? 2)))
    }

    var debugPinnedSize: CGSize { pinned?.panel.frame.size ?? .zero }

    /// For the benchmark's walk-through: zooms the pinned preview, as the wheel would; its scale after.
    func debugZoomPinned(by factor: CGFloat) -> CGFloat {
        guard let inside = pinned?.panel.content as? PreviewPopupView else { return 0 }
        inside.debugZoom(by: factor)
        return inside.debugScale
    }

    /// For the benchmark's walk-through: pins the preview showing.
    func debugPin() { pin() }

    private func pointerInPopupChanged(_ inside: Bool) {
        pointerInsidePopup = inside
        if inside {
            // The preview sets the pointer itself while it is over it.
            state.pointer(over: nil, insidePreview: true, at: now)
            schedule()
        } else {
            pointerMoved(to: pointerOnCanvas())
        }
    }

    /// For the benchmark's walk-through: shows the preview for the link at this canvas point at once.
    func debugShowPreview(at point: NSPoint) {
        guard let hit = link(at: point), case .place(let page, let target) = hit.link.target else {
            var named = ""
            if let session, let canvas, let index = canvas.layout.pageIndex(atY: point.y), let page = session.document.page(at: index) {
                let onPage = PageGeometry.pagePoint(forCanvasPoint: point, pageFrame: canvas.layout.frames[index], page: page)
                if let found = PageLinks.link(at: onPage, in: session.links(onPage: index)), case .figure(let kind, let number, _) = found.target {
                    named = " (\(kind) \(number) on page \(index + 1))"
                }
            }
            return print("  (no link to preview there: the figure or table it names was not found\(named))")
        }
        let hover = Hover(page: hit.page, rect: hit.link.rect, targetPage: page, targetPoint: target, figure: hit.figure)
        if let canvas, let source = session?.document.page(at: hit.page) {
            showBox(around: PageGeometry.canvasRect(forPageRect: hit.link.rect, pageFrame: canvas.layout.frames[hit.page], page: source))
        }
        state.pointer(over: hover, insidePreview: false, at: now - 10)
        if case .show(let ready) = state.timeReached(now) { show(ready) }
        isHeldForWalkThrough = true
    }

    private func hidePopup() {
        popup?.removeFromSuperview()
        popup = nil
        popupHover = nil
        pointerInsidePopup = false
    }
}

/// A pale rounded box, multiplied into the page so the words on it stay black.
private final class LinkHoverBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.linkHover.cgColor
        layer?.cornerRadius = 2
        layer?.compositingFilter = "multiplyBlendMode"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Clicks go to the page beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
