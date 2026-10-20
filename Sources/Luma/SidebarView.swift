import AppKit
import LumaCore
import PDFKit

/// The sidebar: thumbnails or the outline, chosen with the switch at its top.
///
/// Only the chosen view exists. Folding the sidebar away removes it altogether, so that a hidden
/// sidebar paints nothing and holds nothing.
final class SidebarView: NSView {
    static let width: CGFloat = 200

    enum Mode: Int {
        case thumbnails
        case outline
    }

    /// Asked to go to a page; and to a place an outline entry names (page, optional point on it).
    var onSelectPage: ((Int) -> Void)?
    var onSelectPlace: ((Int, CGPoint?) -> Void)?
    /// What editing pages from the thumbnails does.
    var thumbnailActions = ThumbnailActions() {
        didSet { thumbnails?.actions = thumbnailActions }
    }

    private(set) var mode = Mode.thumbnails
    private let switcher = NSSegmentedControl(labels: [L("Thumbnails"), L("Outline")], trackingMode: .selectOne, target: nil, action: nil)
    private var thumbnails: ThumbnailListView?
    private var outline: OutlineListView?
    private weak var session: DocumentSession?
    private var currentPage = 0
    /// The page being read and the height on it of the line read, for the outline.
    private var readingPlace: (page: Int, y: CGFloat?) = (0, nil)
    private var isActive = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        switcher.selectedSegment = 0
        switcher.controlSize = .small
        switcher.segmentDistribution = .fillEqually
        switcher.target = self
        switcher.action = #selector(switched)
        switcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(switcher)
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            switcher.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            switcher.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    @objc private func switched() {
        mode = Mode(rawValue: switcher.selectedSegment) ?? .thumbnails
        install()
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        switcher.selectedSegment = newMode.rawValue
        install()
    }

    /// Shown or folded away. A folded sidebar has no content view at all.
    func setActive(_ active: Bool) {
        isActive = active
        install()
    }

    func show(_ session: DocumentSession?, currentPage: Int) {
        self.session = session
        self.currentPage = currentPage
        readingPlace = (currentPage, nil)
        install()
    }

    /// `page`: the page in the middle of the view, for the thumbnails. `reading`: the line being read,
    /// near the top of the view, for the outline: a heading counts as read once it has scrolled past it.
    /// In a walk-through: clicks an outline entry by the start of its title; describes the outcome.
    func debugClickOutline(_ prefix: String) -> String {
        guard let outline else { return "no outline showing" }
        let clicked = outline.debugClick(titleStartingWith: prefix) ?? "nothing"
        return "clicked \"\(clicked)\", marked \"\(outline.debugCurrentTitle)\""
    }

    /// In a walk-through: drags a thumbnail, as a hand would; false when the thumbnails are not showing.
    func debugPickUpThumbnail(_ index: Int, overGap gap: Int) { thumbnails?.debugPickUp(index, overGap: gap) }
    func debugLetGoOfThumbnail() { thumbnails?.debugLetGo() }
    func debugThumbnailFrame(_ index: Int) -> NSRect? { thumbnails?.debugFrame(index) }

    func debugDragThumbnail(_ index: Int, toGap gap: Int) -> Bool {
        guard let thumbnails else { return false }
        thumbnails.debugDrag(index, toGap: gap)
        return true
    }

    var debugOutlineCurrent: String { outline?.debugCurrentTitle ?? "no outline showing" }

    /// The same file read afresh in the tab in front (ADR 0006): the views stay as they are (mode,
    /// scroll position, what is marked, the keyboard), only pointing at the new session; the outline's
    /// entries are the same, carried over.
    func sameFileReadAfresh(_ session: DocumentSession) {
        guard let previous = self.session, previous.url == session.url, session.pageSizes == previous.pageSizes else {
            return show(session, currentPage: currentPage)
        }
        self.session = session
        thumbnails?.documentReadAfresh(session.document)
        outline?.onCollapsedChange = { [weak session] collapsed in session?.collapsedOutlineEntries = collapsed }
    }

    func setCurrentPage(_ page: Int, reading: (page: Int, y: CGFloat)? = nil) {
        currentPage = page
        readingPlace = reading.map { ($0.page, $0.y) } ?? (page, nil)
        thumbnails?.setCurrentPage(page)
        outline?.setCurrentPlace(page: readingPlace.page, at: readingPlace.y)
    }

    /// After a page edit: the thumbnails laid out again where they were; the outline read again.
    func pagesChanged(currentPage page: Int) {
        currentPage = page
        readingPlace = (page, nil)
        if let thumbnails, let session {
            thumbnails.pagesChanged(pageSizes: session.pageSizes, currentPage: page)
        } else {
            install()
        }
    }

    private var contentFrame: NSRect {
        NSRect(x: 0, y: 38, width: max(0, bounds.width - 1), height: max(0, bounds.height - 38))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        thumbnails?.frame = contentFrame
        outline?.frame = contentFrame
    }

    private func install() {
        thumbnails?.removeFromSuperview()
        thumbnails = nil
        outline?.removeFromSuperview()
        outline = nil
        guard isActive, let session else { return }
        switch mode {
        case .thumbnails:
            let view = ThumbnailListView(frame: contentFrame)
            view.onSelect = { [weak self] page in self?.onSelectPage?(page) }
            view.actions = thumbnailActions
            addSubview(view)
            view.show(session.document, pageSizes: session.pageSizes, currentPage: currentPage)
            thumbnails = view
        case .outline:
            let view = OutlineListView(frame: contentFrame)
            // Without an outline of its own, one is worked out from the text the first time it is asked for.
            session.workOutOutline { [weak self, weak session] in
                guard let self, let session, self.session === session, self.mode == .outline else { return }
                self.install()
            }
            view.emptyText = session.isWorkingOutOutline ? L("Looking for section headings in the text…") : L("This document has no outline")
            let entries = session.outline
            view.onSelect = { [weak self] index in
                guard entries.indices.contains(index), let page = entries[index].page else { return }
                self?.onSelectPlace?(page, entries[index].point)
            }
            view.onCollapsedChange = { [weak session] collapsed in session?.collapsedOutlineEntries = collapsed }
            addSubview(view)
            view.show(entries, collapsed: session.collapsedOutlineEntries, currentPage: readingPlace.page, at: readingPlace.y)
            outline = view
        }
    }
}
