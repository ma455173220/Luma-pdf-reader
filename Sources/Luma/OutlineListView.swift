import AppKit
import LumaCore

/// The surface the outline's rows are painted on.
private final class OutlineCanvas: NSView {
    static let rowHeight: CGFloat = 24
    static let indent: CGFloat = 14

    var entries: [OutlineEntry] = []
    var rows: [Int] = []
    /// The entry for the section the reader is in, if any.
    var currentEntry: Int?
    var hoveredRow: Int? { didSet { if hoveredRow != oldValue { needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    var onToggle: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    private func rowFrame(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * OutlineCanvas.rowHeight, width: bounds.width, height: OutlineCanvas.rowHeight)
    }

    /// The small triangle that folds and unfolds an entry.
    private func toggleBox(_ row: Int) -> NSRect {
        let depth = CGFloat(entries[rows[row]].depth)
        return NSRect(x: 6 + depth * OutlineCanvas.indent, y: CGFloat(row) * OutlineCanvas.rowHeight, width: 16, height: OutlineCanvas.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let first = max(0, Int(dirtyRect.minY / OutlineCanvas.rowHeight))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / OutlineCanvas.rowHeight))
        guard first <= last else { return }
        for row in first...last {
            let entry = entries[rows[row]]
            let frame = rowFrame(row)
            let isCurrent = rows[row] == currentEntry
            if isCurrent || row == hoveredRow {
                NSColor.labelColor.withAlphaComponent(isCurrent ? 0.09 : 0.05).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            let box = toggleBox(row)
            if entry.hasChildren {
                // Pointing right when folded, down when open.
                let folded = !(row + 1 < rows.count && entries[rows[row + 1]].depth > entry.depth)
                let centre = NSPoint(x: box.midX, y: box.midY)
                let triangle = NSBezierPath()
                if folded {
                    triangle.move(to: NSPoint(x: centre.x - 2.5, y: centre.y - 4))
                    triangle.line(to: NSPoint(x: centre.x + 3, y: centre.y))
                    triangle.line(to: NSPoint(x: centre.x - 2.5, y: centre.y + 4))
                } else {
                    triangle.move(to: NSPoint(x: centre.x - 4, y: centre.y - 2.5))
                    triangle.line(to: NSPoint(x: centre.x + 4, y: centre.y - 2.5))
                    triangle.line(to: NSPoint(x: centre.x, y: centre.y + 3))
                }
                triangle.close()
                NSColor.tertiaryLabelColor.setFill()
                triangle.fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isCurrent ? .medium : .regular),
                .foregroundColor: entry.page == nil ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let textX = box.maxX + 2
            (entry.title as NSString).draw(in: NSRect(x: textX, y: frame.minY + 4.5, width: max(0, frame.width - textX - 8), height: 16), withAttributes: attributes)
        }
    }

    private func row(at point: NSPoint) -> Int? {
        let row = Int((point.y / OutlineCanvas.rowHeight).rounded(.down))
        return row >= 0 && row < rows.count ? row : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = row(at: point) else { return }
        if entries[rows[row]].hasChildren && toggleBox(row).contains(point) {
            onToggle?(rows[row])
        } else {
            onSelect?(rows[row])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hoveredRow = row(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoveredRow = nil }
}

/// The document's outline as a list that folds. Clicking an entry goes to its place.
final class OutlineListView: NSView {
    /// Called with the entry's position in the outline.
    var onSelect: ((Int) -> Void)?
    /// Called when the reader folds or unfolds an entry, with the new set of folded entries.
    var onCollapsedChange: ((Set<Int>) -> Void)?

    private let scrollView = NSScrollView()
    private let canvas = OutlineCanvas()
    private let emptyLabel = NSTextField(labelWithString: L("This document has no outline"))
    /// What shows when there are no entries.
    var emptyText: String {
        get { emptyLabel.stringValue }
        set { emptyLabel.stringValue = newValue }
    }
    private var collapsed = Set<Int>()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = canvas
        addSubview(scrollView)

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 40),
        ])
        canvas.onToggle = { [weak self] entry in self?.toggle(entry) }
        canvas.onSelect = { [weak self] entry in
            guard let self else { return }
            self.onSelect?(entry)
            // The entry clicked is the one shown as current, even where the page could not be scrolled
            // to put it at the top (near the end of the document), until the reader moves on.
            self.chosen = (entry, self.place)
            self.markCurrent(entry)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeCanvas()
    }

    /// Where the reader is: the page, and the height on it of the line being read.
    private var place: (page: Int, y: CGFloat?) = (0, nil)
    /// An entry the reader clicked, and where the reader was then.
    private var chosen: (entry: Int, place: (page: Int, y: CGFloat?))?

    func show(_ entries: [OutlineEntry], collapsed: Set<Int>, currentPage: Int, at y: CGFloat? = nil) {
        self.collapsed = collapsed
        canvas.entries = entries
        place = (currentPage, y)
        chosen = nil
        canvas.currentEntry = DocumentOutline.entry(containing: currentPage, at: y, in: entries)
        emptyLabel.isHidden = !entries.isEmpty
        reload()
    }

    func setCurrentPlace(page: Int, at y: CGFloat?) {
        let moved = page != place.page || abs((y ?? 0) - (place.y ?? 0)) > 1
        place = (page, y)
        if let chosen, !moved || (chosen.place.page == page && abs((chosen.place.y ?? 0) - (y ?? 0)) <= 1) { return }
        chosen = nil
        markCurrent(DocumentOutline.entry(containing: page, at: y, in: canvas.entries))
    }

    /// In a walk-through: clicks the first entry whose title starts with `prefix`; returns its title.
    func debugClick(titleStartingWith prefix: String) -> String? {
        guard let entry = canvas.entries.firstIndex(where: { $0.title.hasPrefix(prefix) }) else { return nil }
        canvas.onSelect?(entry)
        return canvas.entries[entry].title
    }

    /// The title of the entry shown as current.
    var debugCurrentTitle: String { canvas.currentEntry.map { canvas.entries[$0].title } ?? "none" }

    private func markCurrent(_ entry: Int?) {
        guard entry != canvas.currentEntry else { return }
        canvas.currentEntry = entry
        canvas.needsDisplay = true
    }

    private func toggle(_ entry: Int) {
        if collapsed.contains(entry) { collapsed.remove(entry) } else { collapsed.insert(entry) }
        onCollapsedChange?(collapsed)
        reload()
    }

    private func reload() {
        canvas.rows = DocumentOutline.visibleRows(canvas.entries, collapsed: collapsed)
        canvas.hoveredRow = nil
        resizeCanvas()
        canvas.needsDisplay = true
    }

    private func resizeCanvas() {
        canvas.setFrameSize(NSSize(width: scrollView.contentView.bounds.width, height: CGFloat(canvas.rows.count) * OutlineCanvas.rowHeight + 8))
    }
}
