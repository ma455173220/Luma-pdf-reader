import AppKit
import LumaCore
import PDFKit

private extension NSToolbarItem.Identifier {
    static let zoomOut = NSToolbarItem.Identifier("luma.zoomOut")
    static let zoomIn = NSToolbarItem.Identifier("luma.zoomIn")
    static let fitWidth = NSToolbarItem.Identifier("luma.fitWidth")
    static let sidebar = NSToolbarItem.Identifier("luma.sidebar")
    static let search = NSToolbarItem.Identifier("luma.search")
    static let magnifier = NSToolbarItem.Identifier("luma.magnifier")
    static let pageIndicator = NSToolbarItem.Identifier("luma.pageIndicator")
    static let rotate = NSToolbarItem.Identifier("luma.rotate")
}

/// Accepts PDF files dropped anywhere on the window.
private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Measured from the top-left, like the canvas, so that floating panels can be placed with the same arithmetic.
    override var isFlipped: Bool { true }

    private func pdfURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["com.adobe.pdf"],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pdfURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = pdfURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// The page number in the toolbar. Clicking it selects the number, ready to be typed over.
private final class PageNumberField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        return true
    }
}

/// The app's single window: a tab strip, one scrolling canvas, and the documents behind the tabs.
///
/// Only the selected document is on the canvas. The others are kept as data, with no picture.
final class ReaderWindowController: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation, NSWindowDelegate, NSTextFieldDelegate {
    let window: NSWindow
    let scrollView = NSScrollView()

    private let tabStrip = TabStripView()
    private let canvas = PageCanvasView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// The page indicator: the page number can be typed over to go to that page; the total follows it.
    private let pageField = PageNumberField(string: "")
    private let pageTotal = NSTextField(labelWithString: "")
    private lazy var pageIndicator: NSStackView = {
        let stack = NSStackView(views: [pageField, pageTotal])
        stack.spacing = 3
        return stack
    }()
    private var tabStripHeight: NSLayoutConstraint?
    private var links: LinkInteractionController?
    private var magnifier: MagnifierController?
    private weak var magnifierItem: NSToolbarItem?
    private let sidebar = SidebarView()
    private var sidebarWidth: NSLayoutConstraint?
    private(set) var isSidebarShown = false
    private let searchBar = SearchBarView()
    private var searchBarHeight: NSLayoutConstraint?
    private let search = SearchController()
    private(set) var isSearchBarShown = false
    /// Whether the place the reader was at has been noted for this search, so that ⌘[ returns there.
    private var searchStartNoted = false
    /// Where the mouse button went down: the canvas point, the page, and the point on that page.
    private var press: (point: NSPoint, page: Int, pagePoint: CGPoint)?
    private var isSelecting = false
    /// A highlight or underline the button went down on; a click on it opens the markup panel.
    private var pressedMark: PDFAnnotation?
    private var markupPanel: FloatingPanelView?
    /// Going through the unsaved documents before closing the window or quitting.
    private var isClosingAll = false
    /// Files asked to open while a question was showing.
    private var waitingFiles: [URL] = []
    /// Things that wanted to show themselves (a document finished opening, a warning) while a
    /// question was showing; they come once it is answered.
    private var waitingWork: [() -> Void] = []

    /// No question is showing, over the window or over the whole app, and the app is not going
    /// through its unsaved documents before closing.
    private var isFree: Bool { window.attachedSheet == nil && NSApp.modalWindow == nil && !isClosingAll }

    /// Does `work` now if nothing is being asked, otherwise once the question is answered.
    private func whenFree(_ work: @escaping () -> Void) {
        if isFree { work() } else { waitingWork.append(work) }
    }

    /// After a question has been answered and taken down: what waited for it comes next, one thing
    /// at a time.
    func afterQuestion() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFree else { return }
            if !self.waitingWork.isEmpty {
                let work = self.waitingWork.removeFirst()
                work()
                self.afterQuestion()
                return
            }
            if !self.waitingFiles.isEmpty {
                let files = self.waitingFiles
                self.waitingFiles = []
                self.open(files)
            }
        }
    }
    /// The colour new marks get: yellow until the reader picks another in the panel, kept until the app quits.
    private var markColour: MarkColour = .yellow
    /// Saving reads and writes files; it happens here, one save at a time, away from the window.
    private let savingQueue = DispatchQueue(label: "luma.save", qos: .userInitiated)
    /// The viewport width the pages are currently laid out for.
    private var laidOutWidth: CGFloat = 0

    private(set) var sessions: [DocumentSession] = []
    private(set) var selectedIndex = 0

    /// Files are read one at a time, off the main thread, so a slow disk never freezes the window
    /// and documents still appear in the order they were asked for.
    private let loadingQueue = DispatchQueue(label: "luma.open", qos: .userInitiated)
    private var loading: [URL] = []

    private var current: DocumentSession? {
        sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil
    }

    var isLoading: Bool { !loading.isEmpty }
    var currentPageCount: Int { current?.document.pageCount ?? 0 }

    /// - Parameter remembersFrame: restore and save the window's place between launches. The benchmark
    ///   turns this off so that it always measures the window size it asked for.
    init(remembersFrame: Bool = true) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "知白"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.center()
        if remembersFrame { window.setFrameAutosaveName("LumaMainWindow") }
        window.delegate = self
        buildContent()
        buildToolbar()
        refresh()
        startSleepingTabs()
        startFreshening()
    }

    // MARK: Building the window

    private func buildContent() {
        let container = DropView(frame: NSRect(x: 0, y: 0, width: 1000, height: 780))
        container.onDrop = { [weak self] urls in self?.open(urls) }

        tabStrip.onSelect = { [weak self] index in self?.select(index) }
        tabStrip.onClose = { [weak self] index in self?.close(index) }

        // The vertical scroller is always there. Where the system shows scrollers permanently, one
        // that came and went would change the page width, the width would change the page height,
        // and a page that just fits would flicker between the two states.
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.canvas
        scrollView.documentView = canvas
        canvas.onMagnify = { [weak self] change, point in self?.magnify(by: change, at: point) }

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)

        // From the top: the tab strip, the search bar, then the sidebar beside the page. The strip, the
        // bar and the sidebar each take no room at all while they are not in use.
        for view in [tabStrip, searchBar, sidebar, scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        searchBar.isHidden = true
        sidebar.isHidden = true
        let height = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        tabStripHeight = height
        let barHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        searchBarHeight = barHeight
        let sideWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        sidebarWidth = sideWidth
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: container.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            height,
            searchBar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            barHeight,
            sidebar.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sideWidth,
            scrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        window.contentView = container

        // Going somewhere from the sidebar is a jump like following a link: ⌘[ comes back from it.
        sidebar.onSelectPage = { [weak self] page in self?.follow(page: page, point: nil) }
        sidebar.onSelectPlace = { [weak self] page, point in self?.follow(page: page, point: point) }
        sidebar.thumbnailActions = ThumbnailActions(
            turn: { [weak self] index, clockwise in self?.editPages { $0.pages.turn(index, clockwise: clockwise) } },
            takeOut: { [weak self] index in self?.editPages { $0.pages.takeOut(index) } },
            move: { [weak self] index, gap in self?.editPages { $0.pages.move(index, toGap: gap) } },
            insert: { [weak self] urls, gap in self?.insertPages(from: urls, atGap: gap) },
            open: { [weak self] urls in self?.open(urls) },
            canTakeOut: { [weak self] in (self?.current?.document.pageCount ?? 0) > 1 })

        searchBar.onQueryChange = { [weak self] query in self?.runSearch(query) }
        searchBar.onOptionsChange = { [weak self] _ in
            guard let self else { return }
            self.runSearch(self.searchBar.query)
        }
        searchBar.onNext = { [weak self] in self?.findNext(nil) }
        searchBar.onPrevious = { [weak self] in self?.findPrevious(nil) }
        searchBar.onClose = { [weak self] in self?.setSearchBarShown(false) }
        search.onChange = { [weak self] settled in self?.searchChanged(settled: settled) }

        let links = LinkInteractionController(host: container, scrollView: scrollView, canvas: canvas)
        links.onFollow = { [weak self] page, point in self?.follow(page: page, point: point) }
        self.links = links
        // Text selected in a preview while the search or page-number field has the keyboard: the
        // page takes it, so that ⌘C copies the selection.
        links.onPreviewSelect = { [weak self] in
            guard let self, ReaderWindowController.isTyping(self.window.firstResponder) else { return }
            self.window.makeFirstResponder(self.canvas)
        }
        let magnifier = MagnifierController(host: container, scrollView: scrollView, canvas: canvas)
        self.magnifier = magnifier
        // While the magnifier is on, the pointer belongs to it: no previews, and clicks follow no links.
        canvas.onPointer = { [weak self] point in
            guard let self else { return }
            if self.isMagnifying {
                // Over the pinned preview the lens goes, and the preview sets the pointer.
                let underPinned = point.map { self.links?.isUnderPinned($0) == true } ?? false
                self.magnifier?.pointerMoved(to: underPinned ? nil : point)
            } else {
                self.links?.pointerMoved(to: point)
            }
            // A note sign can be clicked, and the pointer says so; not under a preview, which sets it there.
            if !self.isMagnifying, let point, self.links?.isUnderPreview(point) != true, self.canvas.markWithNoteSign(at: point) != nil {
                NSCursor.pointingHand.set()
            }
        }
        canvas.onMouseDown = { [weak self] point, clicks in self?.mouseDown(at: point, clicks: clicks) ?? false }
        canvas.onMouseDragged = { [weak self] point in self?.mouseDragged(to: point) }
        canvas.onMouseUp = { [weak self] point in self?.mouseUp(at: point) }
        // Text selected in a preview comes first: the page keeps the keyboard while text is selected
        // there (ADR 0006).
        canvas.selectedText = { [weak self] cleaned in self?.links?.previewSelectedText(cleaned: cleaned) ?? self?.selectionText(cleaned: cleaned) }
        // Text selected in the page, or a search result moved to, takes over from a preview's.
        canvas.onSelect = { [weak self] in self?.links?.clearPreviewSelection() }
        // Two quick ways out of the magnifier: the Escape key, and a right click on the page.
        let leaveMagnifier: () -> Bool = { [weak self] in
            guard let self, self.isMagnifying else { return false }
            self.setMagnifying(false)
            return true
        }
        // Escape first puts away the markup panel and the selection, then the magnifier.
        canvas.onEscape = { [weak self] in
            guard let self else { return false }
            guard self.markupPanel != nil || self.canvas.selection != nil else { return leaveMagnifier() }
            self.closeMarkupPanel(keepingNote: true)
            self.canvas.selection = nil
            return true
        }
        canvas.onSecondaryClick = leaveMagnifier

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportScrolled), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportResized), name: NSView.frameDidChangeNotification, object: clip)
        // Moved to a screen with more pixels to the point: a large pinned preview is made smaller to fit.
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    }

    private func buildToolbar() {
        for field in [pageField, pageTotal] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.textColor = .secondaryLabelColor
        }
        // Looks like the label beside it until it is clicked.
        pageField.isBordered = false
        pageField.drawsBackground = false
        pageField.focusRingType = .none
        pageField.alignment = .right
        pageField.cell?.sendsActionOnEndEditing = false
        pageField.target = self
        pageField.action = #selector(pageNumberTyped(_:))
        pageField.delegate = self
        pageField.toolTip = L("Type a page number and press Return")
        pageField.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let toolbar = NSToolbar(identifier: "LumaToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .zoomOut, .zoomIn, .fitWidth, .magnifier, .rotate, .flexibleSpace, .pageIndicator, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = title
            item.toolTip = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.isBordered = true
            item.target = self
            item.action = action
            return item
        }
        switch identifier {
        case .zoomOut: return button(L("Zoom Out"), "minus.magnifyingglass", #selector(zoomOut(_:)))
        case .zoomIn: return button(L("Zoom In"), "plus.magnifyingglass", #selector(zoomIn(_:)))
        case .fitWidth: return button(L("Fit Width"), "arrow.left.and.right", #selector(zoomToFitWidth(_:)))
        case .magnifier:
            let item = button(L("Magnifier"), "magnifyingglass.circle", #selector(toggleMagnifier(_:)))
            magnifierItem = item
            return item
        case .sidebar: return button(L("Sidebar"), "sidebar.left", #selector(toggleSidebar(_:)))
        case .rotate: return button(L("Rotate this page right"), "rotate.right", #selector(rotatePageRight(_:)))
        case .search: return button(L("Find"), "magnifyingglass", #selector(showSearch(_:)))
        case .pageIndicator:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L("Page")
            item.view = pageIndicator
            return item
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { current != nil }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // While a question is showing over the window, the document behind it is left as it is.
        if window.attachedSheet != nil || NSApp.modalWindow != nil { return false }
        switch menuItem.action {
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): return sessions.count > 1
        case #selector(closeCurrentTab(_:)): return true
        case #selector(goBack(_:)): return current?.history.canGoBack ?? false
        case #selector(goForward(_:)): return current?.history.canGoForward ?? false
        case #selector(toggleMagnifier(_:)):
            menuItem.state = isMagnifying ? .on : .off
            return current != nil
        case #selector(toggleSidebar(_:)):
            menuItem.state = isSidebarShown ? .on : .off
            return current != nil
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return !search.results.isEmpty
        case #selector(saveDocument(_:)):
            // Also when the only change is a note still being written in the markup panel.
            guard let session = current, !session.isSaving else { return false }
            return session.hasUnsavedChanges || markupPanel != nil
        case #selector(rotatePageRight(_:)), #selector(rotatePageLeft(_:)):
            // Not while typing into the search bar or the page number: ⌘R and ⌘L there are not about the page.
            return current != nil && !ReaderWindowController.isTyping(window.firstResponder)
        case #selector(saveDocumentAs(_:)) where current?.isAsleep == true:
            return false
        case #selector(saveDocumentAs(_:)):
            guard let session = current else { return false }
            return !session.isSaving
        case #selector(reloadDocument(_:)):
            // Offered when the file on disk is no longer the one that was read or last saved.
            guard let session = current, !session.isSaving else { return false }
            return DocumentSession.FileStamp.of(session.url).map { $0 != session.fileStamp } ?? false
        default: return current != nil
        }
    }

    // MARK: Opening and closing documents

    /// Opens the files, each in its own tab. Returns at once; reading happens in the background.
    func open(_ urls: [URL]) {
        // Not while a question is showing: the document it is about stays in front.
        guard isFree else {
            waitingFiles += urls
            return
        }
        for url in urls {
            let file = url.standardizedFileURL
            // The same file reached by another path (a link to it) is the same document.
            if let existing = sessions.firstIndex(where: { $0.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }) {
                select(existing)
                continue
            }
            guard !loading.contains(file) else { continue }
            guard FileManager.default.fileExists(atPath: file.path) else {
                warn(L("Can’t find “%@”", file.lastPathComponent), L("It may have been moved, renamed or deleted."))
                continue
            }
            loading.append(file)
            loadingQueue.async { [weak self] in
                // The file as it was before reading it, so that a change made while it is read is noticed.
                let stamp = DocumentSession.FileStamp.of(file)
                let document = PDFDocument(url: file)
                DispatchQueue.main.async { self?.finishOpening(file, document, stamp) }
            }
        }
        refreshEmptyLabel()
        if Benchmark.isRequested { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }
    }

    private func finishOpening(_ file: URL, _ document: PDFDocument?, _ stamp: DocumentSession.FileStamp?) {
        // The window was closed meanwhile: this one is not wanted any more.
        guard loading.contains(file) else { return }
        // A document read while a question shows comes in front once it is answered.
        guard isFree else { return waitingWork.append { [weak self] in self?.finishOpening(file, document, stamp) } }
        loading.removeAll { $0 == file }
        defer { refreshEmptyLabel() }
        let name = file.lastPathComponent
        guard let document else {
            warn(L("Can’t open “%@”", name), L("It may not be a PDF, or it may be damaged."))
            return
        }
        let neededPassword = document.isLocked
        if document.isLocked && !unlock(document, name: name) { return }
        guard document.pageCount > 0 else {
            warn(L("Can’t open “%@”", name), L("This document has no pages."))
            return
        }
        rememberPosition()
        // The system keeps the list behind 「打开最近使用」 and the Dock menu. A walk-through opens
        // scratch copies, which have no place there.
        if !Benchmark.isRequested { NSDocumentController.shared.noteNewRecentDocumentURL(file) }
        let session = makeSession(file, document, stamp: stamp)
        session.neededPassword = neededPassword
        sessions.append(session)
        // While a question shows, the tab it is about stays in front; the new one waits beside it.
        selectedIndex = sessions.count - 1
        refresh()
    }

    /// A session for a document just read from `file`, checking in the background whether marks can
    /// be saved into it. `stamp` is the file as it was before it was read: if it changed while being
    /// read, saving will find that out and say so.
    /// `knownCheck`: the outcome of the check below, already made for this very file as it is (when a
    /// tab is woken or read afresh and the file has not changed), so not made again.
    private func makeSession(_ file: URL, _ document: PDFDocument, stamp: DocumentSession.FileStamp?,
                             knownCheck: PDFAppendError?? = nil) -> DocumentSession {
        let session = DocumentSession(url: file, document: document)
        session.fileStamp = stamp
        session.markup.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.markupChanged(in: session)
        }
        session.pages.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.pagesChanged(in: session)
        }
        if let knownCheck {
            session.markupBlockedBy = knownCheck
            session.markupChecked = true
            return session
        }
        // Find out now, not when the reader tries to save, whether marks can be saved into this file.
        checksMade += 1
        savingQueue.async { [weak session] in
            // One copy of the file's bytes, let go as soon as the check is done (ADR 0005).
            let reason = autoreleasepool { PDFAppendWriter.reasonAnnotationsCannotBeSaved(file: file) }
            DispatchQueue.main.async {
                session?.markupBlockedBy = reason
                session?.markupChecked = true
            }
        }
        return session
    }

    private func unlock(_ document: PDFDocument, name: String) -> Bool {
        var detail = L("Enter the password to open it.")
        while true {
            let alert = NSAlert()
            alert.messageText = L("“%@” is password-protected", name)
            alert.informativeText = detail
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: L("Open"))
            alert.addButton(withTitle: L("Cancel"))
            alert.window.initialFirstResponder = field
            let answer = alert.runModal()
            afterQuestion()
            guard answer == .alertFirstButtonReturn else { return false }
            if document.unlock(withPassword: field.stringValue) { return true }
            detail = L("That password is not right. Try again.")
        }
    }

    private func warn(_ message: String, _ detail: String) {
        // A walk-through has no hand to press 好: the warning goes to its log instead.
        if Benchmark.isRequested {
            print("  (warned: \(message) | \(detail))")
            return afterQuestion()
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
        afterQuestion()
    }

    func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        // Choosing a tab that could not be read when last chosen tries it again.
        if sessions[index].isAsleep && sessions[index].couldNotWake {
            sessions[index].couldNotWake = false
            if index == selectedIndex { return refresh() }
        }
        guard index != selectedIndex else { return }
        current?.lastShown = Date()
        rememberPosition()
        selectedIndex = index
        refresh()
    }

    /// Closes a tab, first asking about unsaved marks.
    func close(_ index: Int) {
        guard sessions.indices.contains(index), isFree else { return }
        let session = sessions[index]
        if session.isSaving { return warn(L("“%@” is being saved", session.title), L("Wait for the save to finish before closing it.")) }
        // A note being written in this tab counts among its unsaved marks.
        closeMarkupPanel(keepingNote: true)
        defer { afterQuestion() }
        guard confirmDiscarding(session) else { return }
        // Saving page edits reads the file again into a new session in the same tab: that one goes.
        guard let kept = ReaderWindowController.sameDocument(as: session, among: sessions),
              let position = sessions.firstIndex(where: { $0 === kept }) else { return }
        closeWithoutAsking(position)
    }

    private func closeWithoutAsking(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        links?.documentClosed(sessions[index].url)
        rememberPosition()
        let next = TabList.selection(afterClosing: index, selected: selectedIndex, count: sessions.count)
        sessions.remove(at: index)
        selectedIndex = next ?? 0
        refresh()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard window.attachedSheet == nil else { return }
        if current == nil { window.performClose(sender) } else { close(selectedIndex) }
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard sessions.count > 1 else { return }
        select((selectedIndex + 1) % sessions.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard sessions.count > 1 else { return }
        select((selectedIndex + sessions.count - 1) % sessions.count)
    }

    // MARK: Showing the current document

    private var viewportSize: CGSize { scrollView.contentView.bounds.size }

    /// Notes what is at the top-left of the viewport, so the tab can be restored to the same spot later.
    private func rememberPosition() {
        // A tab shown empty because it could not be woken keeps the place it slept at.
        guard current?.isAsleep != true else { return }
        current?.position = canvas.layout.anchor(at: scrollView.contentView.bounds.origin)
    }

    private func refreshEmptyLabel() {
        emptyLabel.isHidden = current != nil
        emptyLabel.stringValue = isLoading ? L("Opening…") : L("Drop a PDF here, or press ⌘O to open one")
    }

    // MARK: Sleeping tabs

    /// How long a tab must have been out of sight before it may sleep (初值, ADR 0005).
    /// LUMA_SLEEP_AFTER=<seconds> sets it for a walk-through.
    private let sleepAfter: TimeInterval = Double(ProcessInfo.processInfo.environment["LUMA_SLEEP_AFTER"] ?? "") ?? 300
    private var sleepTimer: Timer?
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Starts looking, every half minute, for tabs that may sleep; and listens for the system saying
    /// memory is short, when every tab that may sleep does so at once.
    private func startSleepingTabs() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: min(30, max(1, sleepAfter / 2)), repeats: true) { [weak self] _ in
            self?.putIdleTabsToSleep(all: false)
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.putIdleTabsToSleep(all: true) }
        source.resume()
        memoryPressure = source
    }

    /// Puts background tabs to sleep: those out of sight long enough, or with `all`, every one that may.
    private func putIdleTabsToSleep(all: Bool) {
        // Nothing changes under a question or a save that holds the window.
        guard isFree else { return }
        let now = Date()
        for index in sessions.indices where index != selectedIndex {
            let session = sessions[index]
            guard session.maySleep, all || now.timeIntervalSince(session.lastShown) >= sleepAfter else { continue }
            // A preview pinned in it would hold on to its pages.
            links?.documentClosed(session.url)
            sessions[index] = session.asleep()
        }
    }

    /// In a walk-through: puts every background tab that may sleep to sleep now.
    func debugPutTabsToSleep() { putIdleTabsToSleep(all: true) }

    /// In a walk-through: the tab in front read afresh now, whether or not it is idle. Whether it
    /// could, and how long it took.
    func debugRefreshFront() -> (done: Bool, seconds: Double) {
        let start = Date()
        let done = freshenFront()
        return (done, Date().timeIntervalSince(start))
    }

    var debugFreshenings: Int { freshenings }
    /// For walk-throughs: how many times the open-time save check has been made.
    var debugChecksMade: Int { checksMade }
    private var checksMade = 0

    // MARK: Reading the tab in front afresh (ADR 0006, 丙)

    /// How long the reader must have done nothing in this window before the document in front is
    /// read afresh, giving back what scrolling and searching built up (初值). LUMA_FRESHEN_AFTER=<seconds>
    /// sets it for a walk-through.
    private let freshenAfter: TimeInterval = Double(ProcessInfo.processInfo.environment["LUMA_FRESHEN_AFTER"] ?? "") ?? 60
    /// The last time the reader pressed, scrolled or typed in this window.
    private var lastActivity = Date()
    /// Read afresh once per spell of doing nothing, not again until the reader does something.
    private var freshenedSinceActivity = false
    private var freshenings = 0
    /// While the tab in front is read afresh: the sidebar is kept, not built again.
    private var isFreshening = false
    private var activityMonitor: Any?
    private var freshenTimer: Timer?

    private func startFreshening() {
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                                     .leftMouseDragged, .scrollWheel, .magnify]) { [weak self] event in
            if let self, event.window === self.window {
                self.lastActivity = Date()
                self.freshenedSinceActivity = false
            }
            return event
        }
        freshenTimer = Timer.scheduledTimer(withTimeInterval: min(15, max(1, freshenAfter / 4)), repeats: true) { [weak self] _ in
            self?.freshenIfIdle()
        }
    }

    /// When the document in front may be read afresh: it may sleep (nothing unsaved, nothing to undo
    /// or redo, not being saved, no password); its file is still there and still the one read (not
    /// renamed, moved or replaced meanwhile, as a reference manager may do); nothing is being asked or
    /// opened; and the reader is in the middle of nothing in it: no selection, press or drag, no note
    /// being written, no search bar, no magnifier, no preview showing or pinned. The sidebar may be open:
    /// it is kept as it is (`SidebarView.sameFileReadAfresh`).
    private var mayFreshen: Bool {
        // Not while the outline is being worked out from the text: reading afresh would drop that
        // search and leave the sidebar saying it is still looking (独审一).
        guard let session = current, !session.isAsleep, session.maySleep, isFree, !isLoading, !session.isWorkingOutOutline,
              let known = session.fileStamp, DocumentSession.FileStamp.of(session.url.resolvingSymlinksInPath()) == known else { return false }
        return press == nil && !isSelecting && canvas.selection == nil && markupPanel == nil && !isSearchBarShown && !isMagnifying
            && !(links?.isShowingPreview ?? false) && !(links?.isShowingPinned ?? false)
    }

    private func freshenIfIdle() {
        guard !freshenedSinceActivity, Date().timeIntervalSince(lastActivity) >= freshenAfter, mayFreshen else { return }
        freshenedSinceActivity = true
        _ = freshenFront()
    }

    /// The tab in front put to sleep and woken at once: its document read afresh from the file, the
    /// reader left where they were (as waking does). Whether it was done.
    @discardableResult
    private func freshenFront() -> Bool {
        guard let session = current, mayFreshen else { return false }
        rememberPosition()
        // The keyboard stays where it was (the page, the outline), and the sidebar as it is.
        let focus = window.firstResponder
        sessions[selectedIndex] = session.asleep()
        isFreshening = true
        refresh()
        isFreshening = false
        if let focus, let view = focus as? NSView, view.window === window, window.firstResponder !== focus { window.makeFirstResponder(view) }
        let done = !(current?.isAsleep ?? true)
        if done { freshenings += 1 }
        return done
    }
    var debugSleepingTabs: Int { sessions.filter(\.isAsleep).count }
    var debugCurrentPlace: PageLayout.Anchor? { currentPlace }

    /// Reads a sleeping tab's file again, under the small panel, and puts the reader back where they
    /// were. A file that cannot be read just now (moved, or being rewritten by another program) leaves
    /// the tab asleep: the reader is told, and it is tried again the next time the tab is chosen.
    private func wake(_ index: Int) {
        let sleeping = sessions[index]
        let file = sleeping.url.resolvingSymlinksInPath()
        let (document, stamp) = whileShowingProgress(L("Reading “%@”…", sleeping.title), on: loadingQueue) {
            let stamp = DocumentSession.FileStamp.of(file)
            return (PDFDocument(url: file), stamp)
        }
        guard let document, document.pageCount > 0, !document.isLocked else {
            sleeping.couldNotWake = true
            if document?.isLocked == true {
                return warn(L("“%@” now needs a password", sleeping.title), L("While it was in the background, the file was replaced by one with a password. The tab stays; close it and open the file again to enter the password."))
            }
            return warn(L("Can’t read “%@” just now", sleeping.title), L("It may have been moved, or another app may be rewriting it. The tab stays, and it is tried again the next time you switch to it."))
        }
        // The file as it was when the tab went to sleep: the check made then still holds.
        let unchanged = stamp != nil && stamp == sleeping.fileStamp && sleeping.markupChecked
        let awake = makeSession(sleeping.url, document, stamp: stamp, knownCheck: unchanged ? .some(sleeping.markupBlockedBy) : nil)
        sleeping.carry(to: awake, fileChanged: stamp != sleeping.fileStamp)
        awake.fileStamp = stamp
        sessions[index] = awake
    }

    /// Brings the whole window in line with `sessions` and `selectedIndex`.
    private func refresh() {
        // A sleeping tab brought to the front wakes first; tried once each time it is chosen.
        if let session = current, session.isAsleep, !session.couldNotWake {
            wake(selectedIndex)
        }
        current?.lastShown = Date()
        // A note being written is kept, in the document it was written in.
        closeMarkupPanel(keepingNote: true)
        press = nil
        isSelecting = false
        pressedMark = nil
        canvas.selection = nil
        window.isDocumentEdited = sessions.contains { $0.hasUnsavedChanges }
        tabStrip.titles = sessions.map(\.tabTitle)
        tabStrip.selectedIndex = selectedIndex
        // With a single document the strip would only take space away from the page.
        tabStripHeight?.constant = sessions.count > 1 ? TabStripView.height : 0
        window.contentView?.layoutSubtreeIfNeeded()
        refreshEmptyLabel()
        window.title = current?.title ?? "知白"
        pageField.isEnabled = current != nil
        // The file's icon beside the title: ⌘-click it to see the folder, or drag it out.
        window.representedURL = current?.url
        links?.session = current
        if current == nil { setMagnifying(false) }
        if isFreshening, let current { sidebar.sameFileReadAfresh(current) } else { sidebar.show(current, currentPage: 0) }
        // A search belongs to one document. In another tab the same words are looked for afresh.
        searchStartNoted = false
        search.cancel()
        canvas.searchResults = SearchResults()
        if let session = current {
            display(session, keeping: session.position, at: .zero)
            if isSearchBarShown { runSearch(searchBar.query) } else { window.makeFirstResponder(canvas) }
        } else {
            scrollView.hasHorizontalScroller = false
            canvas.show(nil, layout: PageLayout(pageSizes: [], scale: 1, viewportWidth: viewportSize.width))
            pageField.stringValue = ""
            pageTotal.stringValue = ""
        }
        window.toolbar?.validateVisibleItems()
    }

    /// Lays the document out at its current scale and scrolls so that `anchor` sits at `offset`,
    /// measured from the viewport's top-left corner.
    private func display(_ session: DocumentSession, keeping anchor: PageLayout.Anchor?, at offset: CGPoint) {
        if session.fitsWidth {
            session.scale = PageLayout.fitWidthScale(pageSizes: session.pageSizes, viewportWidth: viewportSize.width)
        }
        let layout = PageLayout(pageSizes: session.pageSizes, scale: session.scale, viewportWidth: viewportSize.width)
        laidOutWidth = viewportSize.width
        canvas.show(session.document, layout: layout)
        // The horizontal scroller is only there while there is something to scroll sideways. Showing
        // it changes the viewport's height, never its width, so it cannot disturb the layout.
        scrollView.hasHorizontalScroller = layout.contentSize.width > viewportSize.width + 0.5

        let clip = scrollView.contentView
        clip.scroll(to: Viewport.origin(placing: anchor, at: offset, in: layout, viewportSize: viewportSize))
        scrollView.reflectScrolledClipView(clip)
        updatePageLabel()
        // The page under the pointer is no longer what it was.
        links?.dismiss()
        magnifier?.refresh()
    }

    private func updatePageLabel() {
        pageAtTop = current.flatMap { session in currentPlace.flatMap { session.document.page(at: $0.page) } }
        guard let session = current, let page = canvas.layout.pageIndex(atY: scrollView.contentView.bounds.midY) else {
            pageField.stringValue = ""
            pageTotal.stringValue = ""
            return
        }
        // Not while the reader is typing a page number into it.
        if pageField.currentEditor() == nil { pageField.stringValue = "\(page + 1)" }
        pageTotal.stringValue = "/ \(session.document.pageCount)"
        sidebar.setCurrentPage(page, reading: readingPlace())
    }

    /// The line being read: a little below the top of the view, where going to a place puts it; as a
    /// page and a height in that page's coordinates.
    private func readingPlace() -> (page: Int, y: CGFloat)? {
        guard let session = current else { return nil }
        let line = scrollView.contentView.bounds.minY + PageLayout.gap + 24
        guard let index = canvas.layout.pageIndex(atY: line), canvas.layout.frames.indices.contains(index),
              let page = session.document.page(at: index) else { return nil }
        let frame = canvas.layout.frames[index]
        return (index, PageGeometry.pagePoint(forCanvasPoint: CGPoint(x: frame.midX, y: line), pageFrame: frame, page: page).y)
    }

    // MARK: Going to a page by number

    /// 「到页…」: puts the cursor in the page number, ready to type over it.
    @objc func typePageNumber(_ sender: Any?) {
        guard current != nil, window.attachedSheet == nil else { return }
        window.makeFirstResponder(pageField)
        pageField.currentEditor()?.selectAll(nil)
    }

    /// Return in the page number: goes to that page of the PDF, counting its pages from 1.
    @objc private func pageNumberTyped(_ sender: NSTextField) {
        guard let session = current else { return }
        if let index = PageJump.pageIndex(from: sender.stringValue, pageCount: session.document.pageCount) {
            follow(page: index, point: nil)
        } else {
            NSSound.beep()
        }
        window.makeFirstResponder(canvas)
        updatePageLabel()
    }

    /// Escape in the page number puts back the page being shown.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === pageField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        window.makeFirstResponder(canvas)
        updatePageLabel()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextField) === pageField { updatePageLabel() }
    }

    @objc private func viewportScrolled() {
        updatePageLabel()
        // The markup panel belongs to where the text was. While a selection is being dragged it is not open.
        if press == nil { closeMarkupPanel(keepingNote: true) }
        links?.viewScrolled()
        magnifier?.refresh()
    }

    @objc private func screenChanged() {
        links?.containerResized()
    }

    @objc private func viewportResized() {
        links?.containerResized()
        // Only a change of width moves the pages; a change of height just shows more or less of them.
        guard let session = current, abs(viewportSize.width - laidOutWidth) > 0.5 else { return }
        display(session, keeping: canvas.layout.anchor(at: scrollView.contentView.bounds.origin), at: .zero)
    }

    /// Scrolls so that the top of the given page sits at the top of the viewport, without moving sideways.
    func goToPage(_ index: Int) {
        guard current != nil, canvas.layout.frames.indices.contains(index) else { return }
        let clip = scrollView.contentView
        let highest = max(0, canvas.layout.contentSize.height - clip.bounds.height)
        let target = min(max(canvas.layout.frames[index].minY - PageLayout.gap, 0), highest)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Selecting text and marking it

    private func pageHit(_ point: NSPoint) -> (index: Int, page: PDFPage, pagePoint: CGPoint)? {
        guard let session = current, let index = canvas.layout.pageIndex(atY: point.y),
              canvas.layout.frames[index].contains(point), let page = session.document.page(at: index) else { return nil }
        return (index, page, PageGeometry.pagePoint(forCanvasPoint: point, pageFrame: canvas.layout.frames[index], page: page))
    }

    private func mouseDown(at point: NSPoint, clicks: Int) -> Bool {
        // A press in the page leaves no text selected in a preview, so that ⌘C copies the page's.
        links?.clearPreviewSelection()
        if isMagnifying { return true }
        closeMarkupPanel(keepingNote: true)
        links?.dismiss()
        isSelecting = false
        pressedMark = nil
        guard let hit = pageHit(point) else {
            press = nil
            canvas.selection = nil
            // A note sign can stick out past the page edge.
            pressedMark = canvas.markWithNoteSign(at: point)
            return true
        }
        press = (point, hit.index, hit.pagePoint)
        // A double click takes a word, a triple click a line.
        if clicks >= 2 {
            canvas.selection = clicks == 2 ? hit.page.selectionForWord(at: hit.pagePoint) : hit.page.selectionForLine(at: hit.pagePoint)
            isSelecting = true
            return true
        }
        canvas.selection = nil
        if let annotation = canvas.markWithNoteSign(at: point) ?? hit.page.annotation(at: hit.pagePoint), MarkupEditor.isMark(annotation) {
            pressedMark = annotation
        }
        return true
    }

    private func mouseDragged(to point: NSPoint) {
        guard !isMagnifying, let press, let session = current, let startPage = session.document.page(at: press.page) else { return }
        // A small wobble during a click is not a drag.
        if !isSelecting && hypot(point.x - press.point.x, point.y - press.point.y) < 3 { return }
        isSelecting = true
        pressedMark = nil
        let y = min(max(point.y, 0), canvas.layout.contentSize.height)
        guard let endIndex = canvas.layout.pageIndex(atY: y), let endPage = session.document.page(at: endIndex) else { return }
        // Beyond the edge of a page, the selection runs to the nearest point on it.
        let frame = canvas.layout.frames[endIndex]
        let onFrame = NSPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(y, frame.minY), frame.maxY))
        let endPoint = PageGeometry.pagePoint(forCanvasPoint: onFrame, pageFrame: frame, page: endPage)
        canvas.selection = session.document.selection(from: startPage, at: press.pagePoint, to: endPage, at: endPoint)
    }

    private func mouseUp(at point: NSPoint) {
        guard !isMagnifying else { return }
        defer { press = nil }
        if isSelecting {
            isSelecting = false
            if let selection = canvas.selection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showMarkupPanel(for: selection)
            } else {
                canvas.selection = nil
            }
            return
        }
        // A link inside a mark is still a link; the rest of the mark, and its note sign, open the markup panel.
        if let mark = pressedMark, canvas.markWithNoteSign(at: point) === mark {
            pressedMark = nil
            return showMarkupPanel(for: mark)
        }
        if links?.clicked(at: point) == true { return }
        if let mark = pressedMark { showMarkupPanel(for: mark) }
        pressedMark = nil
    }

    /// The last line of a selection on the canvas: the panel goes next to it.
    private func canvasRect(of selection: PDFSelection) -> CGRect? {
        guard let session = current, let page = selection.pages.last else { return nil }
        let index = session.document.index(for: page)
        guard index != NSNotFound, canvas.layout.frames.indices.contains(index),
              let lastLine = selection.selectionsByLine().last(where: { $0.pages.contains(page) }) else { return nil }
        return PageGeometry.canvasRect(forPageRect: lastLine.bounds(for: page), pageFrame: canvas.layout.frames[index], page: page)
    }

    private func blockedMode(_ session: DocumentSession) -> MarkupPopoverView.Mode? {
        session.markupBlockedBy.map { .blocked(L("Annotations can’t be added to this document: ") + readableReason($0)) }
    }

    private func showMarkupPanel(for selection: PDFSelection) {
        guard let session = current, !session.isSaving, let anchor = canvasRect(of: selection) else { return }
        let view = MarkupPopoverView(mode: blockedMode(session) ?? .create(colour: markColour))
        view.onColour = { [weak self] colour in self?.markColour = colour }
        view.onMark = { [weak self, weak session] kind, colour, note in
            guard let self, let session else { return }
            if session.markup.meetsMarksThatCannotBeToldApart(selection, kind: kind) {
                // The panel stays open with the note in it: the other kind of mark can still be chosen.
                let (title, detail): (String, String)
                switch kind {
                case .underline: (title, detail) = (L("This text already has two underlines in exactly the same place"),
                                                    L("Saving could not tell them apart, so 知白 does not add another underline here. Try the other kind of annotation."))
                case .strikeOut: (title, detail) = (L("This text already has two strikethroughs in exactly the same place"),
                                                    L("Saving could not tell them apart, so 知白 does not add another strikethrough here. Try the other kind of annotation."))
                case .highlight: (title, detail) = (L("This text already has two highlights in exactly the same place"),
                                                    L("Saving could not tell them apart, so 知白 does not add another highlight here. Try the other kind of annotation."))
                }
                return self.warn(title, detail)
            }
            session.markup.mark(selection, kind: kind, colour: colour, note: note)
            self.markDone()
        }
        presentMarkupPanel(view, near: anchor)
    }

    private func showMarkupPanel(for mark: PDFAnnotation) {
        guard let session = current, !session.isSaving, let page = mark.page else { return }
        let index = session.document.index(for: page)
        guard index != NSNotFound, canvas.layout.frames.indices.contains(index) else { return }
        let twin = session.markup.cannotBeToldApart(mark)
            ? MarkupPopoverView.Mode.blocked(L("Two annotations of the same kind are in exactly the same place here. Saving could not tell them apart, so 知白 neither changes nor deletes them."))
            : session.markup.isTiedToAnother(mark)
            ? MarkupPopoverView.Mode.blocked(L("This annotation goes together with another one (a reply, or a replacement made in another app), so 知白 neither changes nor deletes it."))
            : nil
        let view = MarkupPopoverView(mode: blockedMode(session) ?? twin ?? .edit(colour: MarkColour.exact(mark.color), note: mark.contents ?? ""))
        view.onColour = { [weak self, weak session, weak view] colour in
            // Only a mark in one of the four colours has one ringed; choosing that one changes nothing.
            session?.markup.setColour(colour, of: mark)
            if let note = view?.noteText { session?.markup.setNote(note, of: mark) }
            self?.markDone()
        }
        view.onNote = { [weak self, weak session] note in
            session?.markup.setNote(note, of: mark)
            self?.markDone()
        }
        view.onDelete = { [weak self, weak session] in
            session?.markup.delete(mark)
            self?.markDone()
        }
        presentMarkupPanel(view, near: PageGeometry.canvasRect(forPageRect: mark.bounds, pageFrame: canvas.layout.frames[index], page: page))
    }

    private func markDone() {
        canvas.selection = nil
        closeMarkupPanel(keepingNote: false)
        window.makeFirstResponder(canvas)
    }

    private func presentMarkupPanel(_ view: MarkupPopoverView, near canvasRect: CGRect) {
        closeMarkupPanel(keepingNote: false)
        guard let host = window.contentView else { return }
        let anchor = host.convert(canvasRect, from: canvas)
        let panel = FloatingPanelView(frame: PreviewGeometry.frame(forPreviewOfSize: view.frame.size, near: anchor, in: scrollView.frame), content: view)
        view.onResize = { [weak self, weak panel] height in
            guard let self, let panel else { return }
            panel.frame = PreviewGeometry.frame(forPreviewOfSize: CGSize(width: panel.frame.width, height: height), near: anchor, in: self.scrollView.frame)
        }
        // Escape in the note puts the panel away, keeping what was written.
        view.onEscape = { [weak self] in
            self?.closeMarkupPanel(keepingNote: true)
            if let canvas = self?.canvas { self?.window.makeFirstResponder(canvas) }
        }
        host.addSubview(panel)
        markupPanel = panel
        // A mark's note is shown straight away, without a further click.
        view.showNoteIfAny()
    }

    /// Puts the markup panel away. A note typed into it is kept when `keepingNote`, as if 完成 had been pressed.
    private func closeMarkupPanel(keepingNote: Bool) {
        guard let panel = markupPanel else { return }
        markupPanel = nil
        panel.removeFromSuperview()
        if keepingNote { (panel.content as? MarkupPopoverView)?.finishNoteIfChanged() }
    }

    private func markupChanged(in session: DocumentSession) {
        tabStrip.titles = sessions.map(\.tabTitle)
        window.isDocumentEdited = sessions.contains { $0.hasUnsavedChanges }
        if session === current { canvas.needsDisplay = true }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let session = current, !session.isSaving else { return nil }
        return session.markup.undoManager
    }

    // MARK: Page edits

    /// Why the pages cannot be edited now, said to the reader; nil when they can.
    private func reasonNotToEditPages(_ session: DocumentSession) -> (String, String)? {
        if session.isSaving { return (L("“%@” is being saved", session.title), L("Wait for the save to finish.")) }
        if let blocked = session.markupBlockedBy {
            return (L("Can’t edit the pages of “%@”", session.title), L("Page changes can’t be saved into this document: ") + readableReason(blocked))
        }
        return nil
    }

    /// Makes a page edit in the current document, unless it cannot be saved there.
    private func editPages(_ work: (DocumentSession) -> Void) {
        // A sleeping tab (shown empty when it could not be woken) has no pages of its own to edit.
        guard let session = current, isFree, !session.isAsleep else { return }
        if let (message, detail) = reasonNotToEditPages(session) { return warn(message, detail) }
        closeMarkupPanel(keepingNote: true)
        canvas.selection = nil
        work(session)
    }

    /// The toolbar's turn button and 「显示 › 向右／向左旋转」: the page in the middle of the view,
    /// without opening the thumbnails.
    @objc func rotatePageRight(_ sender: Any?) { rotateShownPage(clockwise: true) }
    @objc func rotatePageLeft(_ sender: Any?) { rotateShownPage(clockwise: false) }

    /// Whether the keyboard is in a text field (its field editor) or other text view.
    static func isTyping(_ responder: NSResponder?) -> Bool { responder is NSText }

    private func rotateShownPage(clockwise: Bool) {
        guard current != nil, let page = canvas.layout.pageIndex(atY: scrollView.contentView.bounds.midY) else { return }
        editPages { $0.pages.turn(page, clockwise: clockwise) }
    }

    /// Inserts every page of the files, in turn, at a gap between the thumbnails.
    private func insertPages(from urls: [URL], atGap gap: Int) {
        editPages { session in
            var position = gap
            var inserted: [String] = []
            var failed: [(name: String, why: String)] = []
            // A file that cannot be inserted is passed over; the others still go in, and the reader
            // is told afterwards which went in and which did not.
            for url in urls {
                let loaded = whileShowingProgress(L("Reading “%@”…", url.lastPathComponent), on: loadingQueue) { PageEditor.loadSource(url) }
                switch loaded {
                case .success(let source):
                    session.pages.insert(source, atGap: position)
                    position += source.document.pageCount
                    inserted.append(url.lastPathComponent)
                case .failure(let problem):
                    let why: String
                    switch problem {
                    case .unreadable: why = L("It can’t be opened. It may not be a PDF, or it may be damaged.")
                    case .damaged: why = L("Its inner structure is not quite standard, so copying pages out of it could damage the original.")
                    case .refused(let reason):
                        switch reason {
                        case "the document to insert from is password-protected": why = L("It is password-protected.")
                        case "the pages to insert use layers, which cannot be carried over": why = L("Its pages use layers, which 知白 can’t carry over.")
                        case "the pages to insert use too many objects": why = L("Its pages hold too much for 知白 to handle.")
                        case "a page names another branch of the page tree than the one that lists it":
                            why = L("Its list of pages contradicts itself, so different readers show it differently; copied over, its pages might not look the same.")
                        default: why = L("知白 can’t handle some of what is in it, so to keep the original safe it was not inserted.")
                        }
                    }
                    failed.append((url.lastPathComponent, why))
                }
            }
            if let (message, detail) = ReaderWindowController.insertReport(inserted: inserted, failed: failed) { warn(message, detail) }
        }
    }

    /// What the reader is told after inserting several files: nothing when all went in; otherwise
    /// which did not and why, and which did.
    static func insertReport(inserted: [String], failed: [(name: String, why: String)]) -> (String, String)? {
        guard !failed.isEmpty else { return nil }
        if failed.count == 1 && inserted.isEmpty { return (L("Can’t insert “%@”", failed[0].name), failed[0].why) }
        let reasons = failed.map { L("“%@”: %@", $0.name, $0.why) }.joined(separator: "\n")
        let names = inserted.map { L("“%@”", $0) }.joined(separator: L(", "))
        let done = inserted.isEmpty ? L("None were inserted.") : L("Inserted: %@.", names)
        return (L("Files not inserted: %ld", failed.count), reasons + "\n\n" + done)
    }

    /// The page at the top of the view, kept as the page itself: a page edit before it changes its number.
    private weak var pageAtTop: PDFPage?

    /// After a page edit, or its undoing: the page and the thumbnails laid out again, the page being
    /// read staying in view wherever it moved to.
    private func pagesChanged(in session: DocumentSession) {
        markupChanged(in: session)
        guard session === current else { return }
        closeMarkupPanel(keepingNote: true)
        canvas.selection = nil
        let count = session.document.pageCount
        var anchor = currentPlace
        if let page = pageAtTop, anchor != nil, case let index = session.document.index(for: page), index != NSNotFound {
            anchor?.page = index
        }
        if let place = anchor, place.page >= count { anchor = PageLayout.Anchor(page: max(0, count - 1)) }
        display(session, keeping: anchor, at: .zero)
        let page = min(canvas.layout.pageIndex(atY: scrollView.contentView.bounds.midY) ?? 0, max(0, count - 1))
        sidebar.pagesChanged(currentPage: page)
        links?.session = session
        links?.pagesChanged()
        search.cancel()
        canvas.searchResults = SearchResults()
        if isSearchBarShown { runSearch(searchBar.query) }
    }

    /// After saving page edits the document is read again from the file, which now has them, so that
    /// what is shown is exactly what was saved and the pages copied in are no longer held twice.
    /// Returns whether the file was read again into the tab.
    @discardableResult
    private func readAgainAfterSaving(_ old: DocumentSession, as other: URL? = nil) -> Bool {
        guard let index = sessions.firstIndex(where: { $0 === old }) else { return false }
        let file = other ?? old.url
        // LUMA_UNREADABLE_AFTER_SAVE: in a walk-through, as if the file just written could not be read.
        let unreadable = Benchmark.isRequested && ProcessInfo.processInfo.environment["LUMA_UNREADABLE_AFTER_SAVE"] != nil
        guard !unreadable, let document = PDFDocument(url: file.resolvingSymlinksInPath()), document.pageCount > 0, !document.isLocked else {
            if other == nil { warn(L("“%@” was saved but could not be read again", old.title), L("Close this tab and open the file again.")) }
            return false
        }
        let fresh = makeSession(file, document, stamp: other == nil ? old.fileStamp : DocumentSession.FileStamp.of(file))
        // A preview pinned over the old reading shows its pages: it goes with it.
        links?.documentClosed(old.url)
        fresh.scale = old.scale
        fresh.fitsWidth = old.fitsWidth
        if old === current { rememberPosition() }
        fresh.position = old.position.map { $0.page < document.pageCount ? $0 : PageLayout.Anchor(page: document.pageCount - 1) }
        sessions[index] = fresh
        if index == selectedIndex { refresh() } else { tabStrip.titles = sessions.map(\.tabTitle) }
        return true
    }

    // MARK: Save As

    /// 「文件 › 另存为…」(⇧⌘S): the document as the reader sees it, unsaved marks and page edits
    /// included, written to a new file that holds only what it still uses (a slim copy: pages taken
    /// out are really gone from it). The original is not touched. The tab then shows the new file.
    @objc func saveDocumentAs(_ sender: Any?) {
        guard let session = current, isFree, !session.isSaving else { return }
        closeMarkupPanel(keepingNote: true)
        if let blocked = session.markupBlockedBy { return warn(L("Can’t save a copy of “%@”", session.title), readableReason(blocked)) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = L("%@ copy.pdf", session.title)
        panel.directoryURL = session.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self, weak session] response in
            guard let self, let session, response == .OK, let target = panel.url else { return }
            DispatchQueue.main.async { self.saveAs(session, to: target) }
        }
    }

    /// Whether two paths lead to the same file: compared by the file itself, so that a path differing
    /// only in letter case (the Mac's disks ignore it), a hard link or a symbolic link is caught.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        func identity(_ url: URL) -> (NSObject & NSCopying)? {
            var file = url.resolvingSymlinksInPath()
            file.removeAllCachedResourceValues()
            return (try? file.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? (NSObject & NSCopying)
        }
        if a.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL { return true }
        guard let first = identity(a), let second = identity(b) else { return false }
        return first.isEqual(second)
    }

    /// Another tab showing the file at `target`, if any: 另存为 must not replace it.
    static func openElsewhere(_ target: URL, among sessions: [DocumentSession], besides session: DocumentSession) -> DocumentSession? {
        sessions.first { $0 !== session && isSameFile(target, $0.url) }
    }

    /// The tab's session for a document after saving: the same one, or, when saving page edits read
    /// the file again into a new session, that one. Never another document, whichever tab is in front.
    static func sameDocument(as session: DocumentSession, among sessions: [DocumentSession]) -> DocumentSession? {
        sessions.first { $0 === session } ?? sessions.first { $0.url == session.url }
    }

    /// Writes the new file under a small panel, then shows it in the tab instead of the original.
    func saveAs(_ session: DocumentSession, to target: URL) {
        let source = session.url.resolvingSymlinksInPath()
        guard !ReaderWindowController.isSameFile(target, source) else {
            return warn(L("Can’t Save As"), L("The new file can’t take the original’s place. To save the changes into the original, use Save (⌘S)."))
        }
        if let other = ReaderWindowController.openElsewhere(target, among: sessions, besides: session) {
            return warn(L("Can’t Save As"), L("“%@” is open in another tab and can’t be replaced. Choose another name, or close that tab first.", other.title))
        }
        let stamp = session.fileStamp
        let pageCount = session.document.pageCount
        let saving = session.markup.startSaving()
        let pageEdits = session.pages.forSaving
        session.isSaving = true
        let outcome = whileShowingProgress(L("Saving a copy of “%@”…", session.title)) {
            Result {
                try ReaderWindowController.writeSaveAs(saving.changes, pages: pageEdits, from: source, expecting: stamp, to: target, pageCount: pageCount)
            }
        }
        session.isSaving = false
        switch outcome {
        case .success:
            if !Benchmark.isRequested { NSDocumentController.shared.noteNewRecentDocumentURL(target) }
            // The tab now shows the new file; the original, and what was unsaved in it, are left as they were.
            if !readAgainAfterSaving(session, as: target), let index = sessions.firstIndex(where: { $0 === session }) {
                // The tab must not stay on the original with the changes the new file took: saving them
                // there later would write into the original. It closes; the new file has everything.
                closeWithoutAsking(index)
                warn(L("Saved as “%@”, but it could not be opened", target.lastPathComponent),
                     L("The changes are all in the new file, and the original is untouched. This tab has been closed; open the new file from the Finder."))
            }
        case .failure(let error):
            warn(L("Couldn’t save a copy of “%@”", session.title), readableReason(error))
        }
    }

    /// The original with the page edits and marks applied, in memory only, then written as a slim
    /// copy to `target`: to a temporary file first, checked, and only then put in place. The original
    /// is read, never written.
    static func writeSaveAs(_ changes: [MarkupChange], pages: (slots: [PageSlot], sources: [Data])?, from source: URL,
                            expecting stamp: DocumentSession.FileStamp?, to target: URL, pageCount: Int) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { throw SaveProblem.missing }
        guard DocumentSession.FileStamp.of(source) == stamp else { throw SaveProblem.changedElsewhere }
        // Read, not mapped: a mapped file cut short by another program meanwhile would bring the reader down.
        let original = try Data(contentsOf: source)
        let arranged = try pages.map { try PDFPageWriter.applying($0.slots, sources: $0.sources, to: original) } ?? original
        let marked = try PDFAppendWriter.applyingReportingRects(changes, to: arranged).data
        let copy = try PDFSlimCopy.making(from: marked)
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(target.lastPathComponent)
        try copy.write(to: temporary)
        guard PDFDocument(url: temporary)?.pageCount == pageCount else { throw SaveProblem.resultUnreadable }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    // MARK: Saving

    private enum SaveProblem: Error {
        case changedElsewhere
        case missing
        case resultUnreadable
    }

    /// Why saving failed or is not possible, in words the reader can act on.
    private func readableReason(_ error: Error) -> String {
        switch error {
        case SaveProblem.changedElsewhere:
            return [L("Another app has changed the original since it was opened. So as not to overwrite those changes, nothing was saved; the annotations are still in the window."),
                    L("Use File › Reload to load the changed original; unsaved annotations are put back in place (you are asked about any that can’t be), and then save.")]
                .joined(separator: L(" "))
        case SaveProblem.missing:
            return L("The original is no longer where it was; it may have been moved to the Trash or deleted. The annotations are still in the window.")
        case SaveProblem.resultUnreadable:
            return L("The file written did not pass its check, and the original is untouched.")
        case PDFAppendError.refused(let why), PDFAppendError.refusedChange(_, let why):
            switch why {
            case "password-protected": return L("It is password-protected.")
            case "digitally signed": return L("It is digitally signed; adding annotations would make the signature show as changed.")
            case "certified by its author": return L("Its author locked it against changes.")
            case "file is larger than 4 GB", "file would grow past 4 GB": return L("The file is too large (over 4 GB).")
            case "the annotation to change is not in the file": return L("The annotation to change is no longer in the file; another app may have changed the original.")
            case "two annotations match equally, so it is not clear which to change": return L("Two annotations in the file are in exactly the same place, and it can’t be told which one to change.")
            case "the same annotation is changed twice in one save": return L("The same annotation appears on two pages and was changed on both, so 知白 can’t tell which change to keep.")
            case "the annotation has replies": return L("Someone has replied to this annotation; deleting it would leave the replies hanging, so 知白 does not delete it.")
            case "the file's packed objects expand too far": return L("Its inner data is too large once unpacked; so as not to run out of memory, 知白 does not handle it.")
            case "the annotation has no usable area": return L("This annotation’s position is not valid.")
            case "the page to annotate does not exist": return L("The page to annotate is no longer in the file.")
            case "the document to insert from is password-protected": return L("The document inserted from is password-protected.")
            case "the pages to insert use layers, which cannot be carried over": return L("The inserted pages use layers, which 知白 can’t carry over.")
            case "the pages to insert use too many objects": return L("The inserted pages hold too much for 知白 to handle.")
            case "a page names another branch of the page tree than the one that lists it":
                return L("Its list of pages contradicts itself, so different readers show it differently; with its pages changed, they might not look the same.")
            default: return L("知白 can’t handle some of what is in this file, so to keep it safe nothing was written.")
            }
        case PDFAppendError.damaged:
            return L("Its inner structure is not quite standard and writing to it could damage it, so 知白 does not write to it.")
        case PDFAppendError.selfCheckFailed:
            return L("The file written did not pass its own check, and the original is untouched. This is a fault in 知白.")
        default:
            return error.localizedDescription
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard window.attachedSheet == nil else { return }
        guard let session = current else { return }
        closeMarkupPanel(keepingNote: true)
        save(session) { _ in }
    }

    /// Why a save cannot start now, said to the reader; nil when it can.
    private func reasonNotToSave(_ session: DocumentSession) -> (String, String)? {
        if session.isSaving { return (L("“%@” is being saved", session.title), L("Wait for the save to finish.")) }
        if let blocked = session.markupBlockedBy { return (L("Can’t save “%@”", session.title), L("Annotations can’t be added to this document: ") + readableReason(blocked)) }
        return nil
    }

    /// Writes the changes into the file: to a temporary copy first, checked, and only then put in the
    /// original's place. Returns the file's stamp afterwards and the rectangles the new marks were
    /// written with. Runs on the saving queue.
    private static func write(_ changes: [MarkupChange], pages: (slots: [PageSlot], sources: [Data])?, to target: URL,
                              expecting stamp: DocumentSession.FileStamp?, pageCount: Int) throws -> (stamp: DocumentSession.FileStamp?, newRects: [CGRect]) {
        guard FileManager.default.fileExists(atPath: target.path) else { throw SaveProblem.missing }
        guard DocumentSession.FileStamp.of(target) == stamp else { throw SaveProblem.changedElsewhere }
        // Read, not mapped: a mapped file cut short by another program meanwhile would bring the reader down.
        let original = try Data(contentsOf: target)
        // Page edits first: the marks name pages by their place once the edits are made.
        let arranged = try pages.map { try PDFPageWriter.applying($0.slots, sources: $0.sources, to: original) } ?? original
        let (output, newRects) = try PDFAppendWriter.applyingReportingRects(changes, to: arranged)
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(target.lastPathComponent)
        try output.write(to: temporary)
        // The engine must open what was written, with every page there, before it replaces anything.
        guard PDFDocument(url: temporary)?.pageCount == pageCount else { throw SaveProblem.resultUnreadable }
        guard DocumentSession.FileStamp.of(target) == stamp else { throw SaveProblem.changedElsewhere }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        return (DocumentSession.FileStamp.of(target), newRects)
    }

    /// A save has written the file: what it wrote counts as saved.
    /// With page edits, the page list is reset at once, so that whatever happens next (the file not
    /// reading again, closing being cancelled) nothing is written twice; then the file is read again.
    private func finishSaving(_ session: DocumentSession, _ saving: MarkupEditor.Saving,
                              _ written: (stamp: DocumentSession.FileStamp?, newRects: [CGRect]), pagesEdited: Bool) {
        session.fileStamp = written.stamp
        session.markup.didSave(saving, newRects: written.newRects)
        guard pagesEdited else { return }
        session.pages.didSave()
        session.forgetWhatWasWorkedOut()
        markupChanged(in: session)
        readAgainAfterSaving(session)
    }

    /// ⌘S: saves in the background, the window staying usable. Calls `done` on the main thread with
    /// whether it worked.
    func save(_ session: DocumentSession, then done: @escaping (Bool) -> Void) {
        if let (message, detail) = reasonNotToSave(session) {
            warn(message, detail)
            return done(false)
        }
        let saving = session.markup.startSaving()
        let pageEdits = session.pages.forSaving
        guard !saving.changes.isEmpty || pageEdits != nil else { return done(true) }
        session.isSaving = true
        window.toolbar?.validateVisibleItems()
        // A link to the file is followed: what changes is the file it points to, not the link.
        let target = session.url.resolvingSymlinksInPath()
        let stamp = session.fileStamp
        let pageCount = session.document.pageCount
        savingQueue.async { [weak self] in
            let outcome = Result {
                try ReaderWindowController.write(saving.changes, pages: pageEdits, to: target, expecting: stamp, pageCount: pageCount)
            }
            DispatchQueue.main.async {
                session.isSaving = false
                switch outcome {
                case .success(let written):
                    self?.finishSaving(session, saving, written, pagesEdited: pageEdits != nil)
                    done(true)
                case .failure(let error):
                    self?.whenFree { [weak self] in
                        guard let self else { return }
                        if self.offerToDrop(error, from: saving, in: session) {
                            self.save(session) { _ in }
                        } else if !ReaderWindowController.isRefusedChange(error) {
                            self.warn(L("Can’t save “%@”", session.title), self.readableReason(error))
                        }
                    }
                    done(false)
                }
                self?.window.toolbar?.validateVisibleItems()
            }
        }
    }

    /// Saving while closing a tab, the window or the app: done before anything else can happen,
    /// so that nothing is changed, opened or closed while the file is being written.
    private func saveBeforeClosing(_ session: DocumentSession) -> Bool {
        if let (message, detail) = reasonNotToSave(session) {
            warn(message, detail)
            return false
        }
        let saving = session.markup.startSaving()
        let pageEdits = session.pages.forSaving
        guard !saving.changes.isEmpty || pageEdits != nil else { return true }
        let target = session.url.resolvingSymlinksInPath()
        let stamp = session.fileStamp
        let pageCount = session.document.pageCount
        session.isSaving = true
        let outcome = whileShowingProgress(L("Saving “%@”…", session.title)) {
            Result { try ReaderWindowController.write(saving.changes, pages: pageEdits, to: target, expecting: stamp, pageCount: pageCount) }
        }
        session.isSaving = false
        switch outcome {
        case .success(let written):
            finishSaving(session, saving, written, pagesEdited: pageEdits != nil)
            return true
        case .failure(let error):
            if offerToDrop(error, from: saving, in: session) { return saveBeforeClosing(session) }
            if !ReaderWindowController.isRefusedChange(error) { warn(L("Can’t save “%@”", session.title), readableReason(error)) }
            return false
        }
    }

    private static func isRefusedChange(_ error: Error) -> Bool {
        if case PDFAppendError.refusedChange = error { return true }
        return false
    }

    /// When the file would not take one of the changes: says which mark it is, and offers to put that
    /// mark back the way the file has it and save the rest. Returns whether the reader chose that.
    private func offerToDrop(_ error: Error, from saving: MarkupEditor.Saving, in session: DocumentSession) -> Bool {
        guard case PDFAppendError.refusedChange(let position, _) = error, saving.changes.indices.contains(position) else { return false }
        let change = saving.changes[position]
        let kind: MarkupAddition.Kind
        let what: String
        switch change {
        case .add(let addition): (kind, what) = (addition.kind, "added")
        case .modify(_, let original, _, _): (kind, what) = (original.kind, "changed")
        case .remove(_, let original): (kind, what) = (original.kind, "deleted")
        }
        let alert = NSAlert()
        // One sentence for each kind of change and mark, so that each language can word it whole.
        let format: String
        switch (what, kind) {
        case ("added", .underline): format = L("An underline added on page %2$ld of “%1$@” can’t be saved into the original")
        case ("added", .strikeOut): format = L("A strikethrough added on page %2$ld of “%1$@” can’t be saved into the original")
        case ("added", _): format = L("A highlight added on page %2$ld of “%1$@” can’t be saved into the original")
        case ("changed", .underline): format = L("An underline changed on page %2$ld of “%1$@” can’t be saved into the original")
        case ("changed", .strikeOut): format = L("A strikethrough changed on page %2$ld of “%1$@” can’t be saved into the original")
        case ("changed", _): format = L("A highlight changed on page %2$ld of “%1$@” can’t be saved into the original")
        case (_, .underline): format = L("An underline deleted on page %2$ld of “%1$@” can’t be saved into the original")
        case (_, .strikeOut): format = L("A strikethrough deleted on page %2$ld of “%1$@” can’t be saved into the original")
        default: format = L("A highlight deleted on page %2$ld of “%1$@” can’t be saved into the original")
        }
        alert.messageText = String(format: format, session.title, change.pageIndex + 1)
        alert.informativeText = readableReason(error) + "\n\n"
            + L("You can drop the change to this one, so that it goes back to how the original has it, and save the rest; or not save yet, keeping all the annotations in the window.")
        alert.addButton(withTitle: L("Drop This One, Save the Rest"))
        alert.addButton(withTitle: L("Don’t Save Yet"))
        let scripted = Benchmark.nextScriptedAnswer()
        if Benchmark.isRequested { print("  (asked: \(alert.messageText) | answer \(scripted ?? "none"))") }
        let answer = scripted.map { $0 == "drop" ? NSApplication.ModalResponse.alertFirstButtonReturn : .alertSecondButtonReturn } ?? alert.runModal()
        afterQuestion()
        guard answer == .alertFirstButtonReturn else { return false }
        session.markup.discard(changeAt: position, of: saving)
        return true
    }

    /// Runs `work` on the saving queue (or `queue`) while a small panel holds the app: nothing else can be done
    /// meanwhile, yet the app does not freeze, and keys pressed in the meantime go to the panel
    /// rather than to the next question. The panel only shows if the work takes a moment.
    private func whileShowingProgress<T>(_ message: String, on queue: DispatchQueue? = nil, _ work: @escaping () -> T) -> T {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "知白"
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, NSTextField(labelWithString: message)])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        row.frame = panel.contentView?.bounds ?? .zero
        row.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(row)
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - panel.frame.width / 2, y: window.frame.midY - panel.frame.height / 2))
        panel.alphaValue = 0
        // Waited for without the main queue, which may itself be the one asking (a queued block
        // cannot run until the block that is running ends).
        var result: T?
        let finished = DispatchGroup()
        finished.enter()
        (queue ?? savingQueue).async {
            result = work()
            finished.leave()
        }
        let started = Date()
        let session = NSApp.beginModalSession(for: panel)
        while finished.wait(timeout: .now() + 0.02) == .timedOut {
            if panel.alphaValue == 0 && Date().timeIntervalSince(started) > 0.3 { panel.alphaValue = 1 }
            _ = NSApp.runModalSession(session)
        }
        NSApp.endModalSession(session)
        panel.orderOut(nil)
        afterQuestion()
        return result!
    }

    /// Asks what to do with a document's unsaved marks before it goes away; true means it may go.
    private func confirmDiscarding(_ session: DocumentSession) -> Bool {
        guard session.hasUnsavedChanges else { return true }
        switch askAboutUnsaved(session) {
        case .alertFirstButtonReturn: return saveBeforeClosing(session)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func askAboutUnsaved(_ session: DocumentSession) -> NSApplication.ModalResponse {
        if let scripted = Benchmark.nextScriptedAnswer() {
            print("  (asked about \(session.title): answered \(scripted))")
            return scripted == "save" ? .alertFirstButtonReturn : scripted == "discard" ? .alertThirdButtonReturn : .alertSecondButtonReturn
        }
        let alert = NSAlert()
        let pages = session.pages.hasUnsavedChanges, marks = session.markup.hasUnsavedChanges
        alert.messageText = String(format: pages && marks ? L("The annotations and page changes in “%@” are not saved")
            : pages ? L("The page changes in “%@” are not saved") : L("The annotations in “%@” are not saved"), session.title)
        alert.informativeText = pages && marks ? L("If you don’t save, the annotations and page changes made this time are lost.")
            : pages ? L("If you don’t save, the page changes made this time are lost.") : L("If you don’t save, the annotations made this time are lost.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel")).keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: L("Don’t Save"))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        return alert.runModal()
    }

    /// Asks about every document with unsaved marks, one after another, looking afresh each time
    /// for one not yet answered; true means all may go. Nothing else happens meanwhile: the questions
    /// hold the app, and each save finishes before the next question.
    func confirmClosingAll() -> Bool {
        guard !isClosingAll else { return false }
        // A save started with ⌘S finishes first: what it writes was asked for, and quitting in the
        // middle of it could leave the original half replaced.
        if let saving = sessions.first(where: \.isSaving) {
            warn(L("“%@” is being saved", saving.title), L("Wait for the save to finish before closing it."))
            return false
        }
        keepNoteBeingWritten()
        isClosingAll = true
        defer {
            isClosingAll = false
            afterQuestion()
        }
        var discarded = Set<ObjectIdentifier>()
        while let next = sessions.first(where: { $0.hasUnsavedChanges && !discarded.contains(ObjectIdentifier($0)) }) {
            if let index = sessions.firstIndex(where: { $0 === next }) { select(index) }
            switch askAboutUnsaved(next) {
            case .alertFirstButtonReturn:
                guard saveBeforeClosing(next) else { return false }
            case .alertThirdButtonReturn:
                discarded.insert(ObjectIdentifier(next))
            default:
                return false
            }
        }
        return true
    }

    /// A note being written in the markup panel becomes a mark, so that it counts as unsaved.
    func keepNoteBeingWritten() {
        closeMarkupPanel(keepingNote: true)
    }

    /// Closing the window closes every tab, after asking about unsaved marks.
    /// The window comes forward after any dialog (an open panel, a password box, a system dialog):
    /// whatever waited for it comes now.
    func windowDidBecomeKey(_ notification: Notification) {
        afterQuestion()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmClosingAll() else { return false }
        sessions = []
        selectedIndex = 0
        // Documents still being read, and anything waiting to show, are no longer wanted.
        loading = []
        waitingWork = []
        waitingFiles = []
        refresh()
        return true
    }

    // MARK: Copying

    /// The selected text: as the PDF has it, or with the lines of each paragraph joined, words
    /// split at line ends mended, and joined letters spelled out.
    private func selectionText(cleaned: Bool) -> String? {
        guard let selection = canvas.selection, let session = current else { return nil }
        guard cleaned else { return selection.string }
        var lines: [CleanCopy.Line] = []
        for line in selection.selectionsByLine() {
            guard let text = line.string else { continue }
            for page in line.pages {
                let index = session.document.index(for: page)
                if index != NSNotFound {
                    lines.append(CleanCopy.Line(text: text, frame: line.bounds(for: page), page: index, pageBox: page.bounds(for: .cropBox)))
                }
            }
        }
        let document = session.document
        var read: [Int: MarginText] = [:]
        return CleanCopy.text(from: lines, isWord: ReaderWindowController.isEnglishWord) { line in
            let around = read[line.page] ?? ReaderWindowController.marginText(around: line.page, in: document)
            read[line.page] = around
            let atTop = line.frame.midY > line.pageBox.midY
            if let number = CleanCopy.bareNumber(line.text) {
                // A page number: a page around has a number next to it in the same strip.
                return (atTop ? around.topNumbers : around.bottomNumbers).contains { abs($0 - number) <= 2 }
            }
            // A running head or foot: the same words in the same strip of at least two pages around
            // (one, when there is only one page around to look at).
            let key = CleanCopy.runningKey(line.text)
            let seen = (atTop ? around.top : around.bottom)[key] ?? 0
            return !key.isEmpty && seen >= min(2, around.pages)
        }
    }

    /// What stands in the top and bottom strips of the pages around a page: for each line's letters,
    /// on how many of those pages it appears; and the bare numbers.
    private struct MarginText {
        var top: [String: Int] = [:]
        var bottom: [String: Int] = [:]
        var topNumbers: [Int] = []
        var bottomNumbers: [Int] = []
        var pages = 0
    }

    /// Reads the top and bottom strips of the two pages before and after a page. Only when a copy
    /// runs across a page.
    private static func marginText(around index: Int, in document: PDFDocument) -> MarginText {
        var text = MarginText()
        for other in [index - 2, index - 1, index + 1, index + 2] where other >= 0 && other < document.pageCount {
            guard let page = document.page(at: other) else { continue }
            text.pages += 1
            let box = page.bounds(for: .cropBox)
            let band = box.height * CleanCopy.marginShare
            for atTop in [true, false] {
                let strip = CGRect(x: box.minX, y: atTop ? box.maxY - band : box.minY, width: box.width, height: band)
                var keys = Set<String>()
                for line in page.selection(for: strip)?.selectionsByLine() ?? [] {
                    let string = line.string ?? ""
                    if let number = CleanCopy.bareNumber(string) {
                        if atTop { text.topNumbers.append(number) } else { text.bottomNumbers.append(number) }
                    }
                    let key = CleanCopy.runningKey(string)
                    if !key.isEmpty { keys.insert(key) }
                }
                for key in keys {
                    if atTop { text.top[key, default: 0] += 1 } else { text.bottom[key, default: 0] += 1 }
                }
            }
        }
        return text
    }

    /// Asks the system's spelling dictionaries, British and American (behaviour as well as behavior).
    /// Only called for a hyphen at the end of a line.
    static func isEnglishWord(_ word: String) -> Bool {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        let languages = ["en_GB", "en_US", "en"].filter(available.contains)
        return (languages.isEmpty ? ["en"] : languages).contains { language in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    // MARK: Reloading

    /// 「文件 › 重新载入」: reads the file again, offered when it has changed on disk since it was
    /// read or last saved (saving says so, when it finds out). The new copy goes in the same tab, at
    /// the same place, with the unsaved marks put back; if some cannot go back, the reader is asked
    /// first. The reading happens under a small panel, as saving before closing does.
    @objc func reloadDocument(_ sender: Any?) {
        guard let old = current, isFree, !old.isSaving else { return }
        // A note being written goes with the marks.
        closeMarkupPanel(keepingNote: true)
        // Page edits are not put back: they name the pages of the file as it was.
        if old.pages.hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = L("Reloading drops the unsaved page changes in “%@”", old.title)
            alert.informativeText = L("Rotated, deleted, moved and inserted pages go back to how they are in the original. Annotations are put back where they can be; you are asked about any that can’t.")
            alert.addButton(withTitle: L("Keep the Window as It Is"))
            alert.addButton(withTitle: L("Reload Anyway"))
            let answer = Benchmark.nextScriptedAnswer().map { $0 == "reload" ? NSApplication.ModalResponse.alertSecondButtonReturn : .alertFirstButtonReturn }
                ?? alert.runModal()
            afterQuestion()
            guard answer == .alertSecondButtonReturn else { return }
        }
        let file = old.url
        let (document, stamp) = whileShowingProgress(L("Reloading “%@”…", old.title), on: loadingQueue) {
            // The state first, then the reading: a change made while reading is then caught when saving.
            let stamp = DocumentSession.FileStamp.of(file)
            return (PDFDocument(url: file), stamp)
        }
        let name = file.lastPathComponent
        guard let document, document.pageCount > 0 else {
            return warn(L("Can’t reload “%@”", name), L("The original can’t be opened just now, or it is no longer where it was. The window still shows what it did."))
        }
        let neededPassword = document.isLocked
        if document.isLocked && !unlock(document, name: name) {
            return warn(L("“%@” was not reloaded", name), L("No password was given. The window still shows what it did."))
        }
        let fresh = makeSession(file, document, stamp: stamp)
        fresh.neededPassword = neededPassword
        // Marks are put back by the page numbers the file has: page edits are not put back.
        let (changes, pageMadeOn, onInserted) = old.pages.toFilePages(old.markup.changesForSaving())
        let earlier: (Int) -> PDFPage? = { pageMadeOn[$0] }
        let unplaced = fresh.markup.reapply(changes, from: earlier, onlyCheck: true)
        if !unplaced.isEmpty || onInserted > 0 {
            let alert = NSAlert()
            alert.messageText = L("Annotations in “%1$@” that can’t be put back in the changed original: %2$ld", old.title, unplaced.count + onInserted)
            // Whole sentences, a space between them in English (none in Chinese).
            alert.informativeText = [onInserted > 0 ? L("On inserted pages, which are gone once reloaded: %ld.", onInserted) : nil,
                                     unplaced.isEmpty ? nil : L("The original’s pages or text have changed, and some annotations no longer match their places."),
                                     L("Reloading drops them. Without reloading, the window stays as it is, but changes can’t be saved either, as the original has changed.")]
                .compactMap { $0 }.joined(separator: L(" "))
            alert.addButton(withTitle: L("Keep the Window as It Is"))
            alert.addButton(withTitle: L("Reload Anyway"))
            let answer = Benchmark.nextScriptedAnswer().map { $0 == "reload" ? NSApplication.ModalResponse.alertSecondButtonReturn : .alertFirstButtonReturn }
                ?? alert.runModal()
            afterQuestion()
            guard answer == .alertSecondButtonReturn else { return }
        }
        guard let index = sessions.firstIndex(where: { $0 === old }) else { return }
        let missed = fresh.markup.reapply(changes, from: earlier)
        fresh.scale = old.scale
        fresh.fitsWidth = old.fitsWidth
        if fresh.document.pageCount == old.document.pageCount { fresh.history = old.history }
        rememberPosition()
        fresh.position = old.position
        links?.documentClosed(old.url)
        sessions[index] = fresh
        refresh()
        // Checked just before, so this should not happen; if it does, the reader hears of it.
        if missed.count > unplaced.count {
            warn(L("Annotations in “%1$@” that could not be put back: %2$ld", fresh.title, missed.count - unplaced.count), L("They no longer matched the changed original when it was reloaded."))
        }
    }

    // MARK: Following links and going back

    private var currentPlace: PageLayout.Anchor? {
        canvas.layout.anchor(at: scrollView.contentView.bounds.origin)
    }

    /// Goes to a place in the current document, remembering where the reader was.
    private func follow(page: Int, point: CGPoint?) {
        guard let session = current, let target = session.document.page(at: page), canvas.layout.frames.indices.contains(page) else { return }
        if let here = currentPlace { session.history.jumped(from: here) }
        var anchor = PageLayout.Anchor(page: page)
        if let point {
            let size = PageRenderer.displaySize(of: target)
            let spot = PageGeometry.displayPoint(forPagePoint: point, on: target)
            anchor = PageLayout.Anchor(page: page, x: size.width > 0 ? spot.x / size.width : 0,
                                       y: size.height > 0 ? min(max(spot.y / size.height, 0), 1) : 0)
        }
        display(session, keeping: anchor, at: CGPoint(x: PageLayout.gap, y: PageLayout.gap))
    }

    @objc func goBack(_ sender: Any?) {
        guard let session = current, let here = currentPlace, let place = session.history.goBack(from: here) else { return }
        display(session, keeping: place, at: .zero)
    }

    @objc func goForward(_ sender: Any?) {
        guard let session = current, let here = currentPlace, let place = session.history.goForward(from: here) else { return }
        display(session, keeping: place, at: .zero)
    }

    // MARK: Sidebar

    private func setSidebarShown(_ shown: Bool) {
        guard shown != isSidebarShown else { return }
        isSidebarShown = shown
        sidebar.isHidden = !shown
        sidebarWidth?.constant = shown ? SidebarView.width : 0
        // Folded away, the sidebar keeps no view of its own: nothing painted, nothing held.
        sidebar.setActive(shown)
        window.contentView?.layoutSubtreeIfNeeded()
        if let page = canvas.layout.pageIndex(atY: scrollView.contentView.bounds.midY) { sidebar.setCurrentPage(page, reading: readingPlace()) }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        guard current != nil || isSidebarShown else { return }
        setSidebarShown(!isSidebarShown)
    }

    func showSidebar(_ mode: SidebarView.Mode) {
        sidebar.setMode(mode)
        setSidebarShown(true)
    }

    // MARK: Search

    private func setSearchBarShown(_ shown: Bool) {
        if shown != isSearchBarShown {
            isSearchBarShown = shown
            searchBar.isHidden = !shown
            searchBarHeight?.constant = shown ? SearchBarView.height : 0
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if shown {
            searchBar.focus()
        } else {
            searchStartNoted = false
            search.cancel()
            canvas.searchResults = SearchResults()
            searchBar.setCount("", hasMatches: false)
            window.makeFirstResponder(canvas)
        }
    }

    @objc func showSearch(_ sender: Any?) {
        guard current != nil else { return }
        setSearchBarShown(true)
    }

    @objc func findNext(_ sender: Any?) { links?.clearPreviewSelection(); search.selectNext() }
    @objc func findPrevious(_ sender: Any?) { links?.clearPreviewSelection(); search.selectPrevious() }

    private func runSearch(_ query: String) {
        guard let session = current else { return }
        searchStartNoted = false
        let page = canvas.layout.pageIndex(atY: scrollView.contentView.bounds.minY) ?? 0
        search.start(query, in: session.document, fromPage: page, options: searchBar.options)
    }

    private func searchChanged(settled: Bool) {
        canvas.searchResults = search.results
        let empty = searchBar.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchBar.setCount(empty ? "" : search.results.label(isSearching: search.isSearching), hasMatches: !search.results.isEmpty)
        if settled { showCurrentMatch() }
    }

    /// Scrolls the match the reader is on into view, a third of the way down, unless it already is in view.
    private func showCurrentMatch() {
        guard let session = current, let match = search.results.currentMatch, let first = match.rects.first,
              let page = session.document.page(at: match.page), canvas.layout.frames.indices.contains(match.page) else { return }
        if !searchStartNoted, let here = currentPlace {
            session.history.jumped(from: here)
            searchStartNoted = true
        }
        let onCanvas = PageGeometry.canvasRect(forPageRect: first, pageFrame: canvas.layout.frames[match.page], page: page)
        let visible = scrollView.contentView.bounds
        guard !visible.insetBy(dx: 0, dy: 30).contains(onCanvas) else { return }
        let highest = CGPoint(x: max(0, canvas.layout.contentSize.width - visible.width), y: max(0, canvas.layout.contentSize.height - visible.height))
        let origin = CGPoint(x: min(max(onCanvas.midX - visible.width / 2, 0), highest.x),
                             y: min(max(onCanvas.minY - visible.height / 3, 0), highest.y))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var debugSearch: String {
        "search=\"\(searchBar.query)\" \(search.results.label(isSearching: search.isSearching)) sidebar=\(isSidebarShown)"
    }

    /// For the benchmark's walk-through: types a query into the search bar as the reader would.
    func debugSearch(for query: String) {
        setSearchBarShown(true)
        searchBar.debugSetQuery(query)
        runSearch(query)
    }

    func debugCloseSearch() { setSearchBarShown(false) }

    /// For the walk-through: searches with the find bar's two options set as given; the count it shows.
    func debugSearch(for query: String, options: SearchOptions) {
        setSearchBarShown(true)
        searchBar.debugSetOptions(options)
        searchBar.debugSetQuery(query)
        runSearch(query)
    }
    var debugSearchCount: String { search.results.label(isSearching: search.isSearching) }
    var debugIsSearching: Bool { search.isSearching }
    func debugHideSidebar() { setSidebarShown(false) }

    // MARK: Magnifier

    var isMagnifying: Bool { magnifier?.isOn ?? false }

    private func setMagnifying(_ on: Bool) {
        guard on != isMagnifying else { return }
        links?.isEnabled = !on
        magnifier?.setOn(on)
        magnifierItem?.image = NSImage(systemSymbolName: on ? "magnifyingglass.circle.fill" : "magnifyingglass.circle", accessibilityDescription: L("Magnifier"))
        if !on { NSCursor.arrow.set() }
    }

    @objc func toggleMagnifier(_ sender: Any?) {
        guard current != nil else { return }
        setMagnifying(!isMagnifying)
    }

    // MARK: For the benchmark's walk-through

    /// Shows the preview of the first link on the pages in view, as if the pointer had rested on it.
    func debugPinPreview() { links?.debugPin() }
    func debugUnpinPreview() { links?.unpin() }
    func debugMakePinnedLargest() { links?.debugMakePinnedLargest() }
    var debugPinnedSize: CGSize { links?.debugPinnedSize ?? .zero }
    func debugZoomPinned(by factor: CGFloat) -> CGFloat { links?.debugZoomPinned(by: factor) ?? 0 }
    var debugIsPinned: Bool { links?.isShowingPinned ?? false }

    /// In a walk-through: whether the document in front reads its figures from a document of its own
    /// just now (ADR 0006).
    var debugFigureReadingHeld: Bool { current?.debugFigureReadingHeld ?? false }

    /// In a walk-through: shows the preview of the link on page `page` (counted from 1) written as
    /// `text`, scrolling to it first. Whether there is one.
    func debugHoverLink(onPage page: Int, written text: String) -> Bool {
        guard let session = current, let shown = session.document.page(at: page - 1) else { return false }
        for link in session.links(onPage: page - 1) {
            // Written as `text`, or starting with it when it ends in "*" ("Fig*").
            let written = (shown.selection(for: link.rect.insetBy(dx: 1, dy: 1))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasSuffix("*") ? written.hasPrefix(text.dropLast()) : written == text else { continue }
            let frame = canvas.layout.frames[page - 1]
            let onCanvas = PageGeometry.canvasRect(forPageRect: link.rect, pageFrame: frame, page: shown)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, onCanvas.midY - scrollView.contentView.bounds.height / 2)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            links?.debugShowPreview(at: NSPoint(x: onCanvas.midX, y: onCanvas.midY))
            return true
        }
        let written = session.links(onPage: page - 1).prefix(12).map { "\"" + (shown.selection(for: $0.rect.insetBy(dx: 1, dy: 1))?.string ?? "") + "\"" }
        print("  (links on page \(page): \(written.joined(separator: " ")))")
        return false
    }

    /// For the demo recordings: scrolls so that the link on page `page` (from 1) written as `text`
    /// sits at `fraction` of the view's height from its top (nil: where it is); where it is then, in
    /// window coordinates.
    func debugPlaceLink(onPage page: Int, written text: String, atFraction fraction: CGFloat?) -> NSRect? {
        guard let session = current, let shown = session.document.page(at: page - 1) else { return nil }
        for link in session.links(onPage: page - 1) {
            let written = (shown.selection(for: link.rect.insetBy(dx: 1, dy: 1))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasSuffix("*") ? written.hasPrefix(text.dropLast()) : written == text else { continue }
            let onCanvas = PageGeometry.canvasRect(forPageRect: link.rect, pageFrame: canvas.layout.frames[page - 1], page: shown)
            if let fraction {
                let clip = scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, onCanvas.midY - clip.bounds.height * fraction)))
                scrollView.reflectScrolledClipView(clip)
            }
            return canvas.convert(onCanvas, to: nil)
        }
        return nil
    }

    /// For the demo recordings: the preview of the link at this window point, as resting the pointer there shows it.
    func debugShowPreview(atWindowPoint point: NSPoint) { links?.debugShowPreview(at: canvas.convert(point, from: nil)) }

    /// For the demo recordings: a rectangle on the page canvas, in window coordinates.
    func debugWindowRect(fromCanvas rect: CGRect) -> NSRect { canvas.convert(rect, to: nil) }

    func debugThumbnailFrame(_ index: Int) -> NSRect? { sidebar.debugThumbnailFrame(index) }

    /// For the demo recordings: the magnifier's lens follows the pointer to this window point.
    func debugMagnifierPointer(atWindowPoint point: NSPoint) { magnifier?.pointerMoved(to: canvas.convert(point, from: nil)) }

    @discardableResult
    func debugHoverFirstVisibleLink(figure: Bool = false) -> Bool {
        guard let session = current else { return false }
        let visible = scrollView.contentView.bounds
        for index in canvas.layout.pages(intersecting: visible) {
            guard let page = session.document.page(at: index) else { continue }
            for link in session.links(onPage: index) {
                if figure { guard case .figure = link.target else { continue } } else { guard case .place = link.target else { continue } }
                let onCanvas = PageGeometry.canvasRect(forPageRect: link.rect, pageFrame: canvas.layout.frames[index], page: page)
                guard visible.insetBy(dx: 0, dy: 40).contains(onCanvas) else { continue }
                links?.debugShowPreview(at: NSPoint(x: onCanvas.midX, y: onCanvas.midY))
                return true
            }
        }
        return false
    }

    /// In a walk-through: points at the first place in view where `text` is written, as the pointer
    /// would, whether or not there is a link there.
    func debugHoverText(_ text: String) -> Bool {
        guard let session = current else { return false }
        let visible = scrollView.contentView.bounds
        for index in canvas.layout.pages(intersecting: visible) {
            guard let page = session.document.page(at: index), let string = page.string as NSString? else { continue }
            var search = NSRange(location: 0, length: string.length)
            while case let found = string.range(of: text, range: search), found.location != NSNotFound {
                search = NSRange(location: found.location + found.length, length: string.length - found.location - found.length)
                guard let rect = page.selection(for: found)?.bounds(for: page) else { continue }
                let onCanvas = PageGeometry.canvasRect(forPageRect: rect, pageFrame: canvas.layout.frames[index], page: page)
                guard visible.insetBy(dx: 0, dy: 40).contains(onCanvas) else { continue }
                links?.debugShowPreview(at: NSPoint(x: onCanvas.midX, y: onCanvas.midY))
                return true
            }
        }
        return false
    }

    /// In a walk-through: clicks an outline entry; says which was clicked and which is marked current.
    func debugClickOutline(_ prefix: String) -> String { sidebar.debugClickOutline(prefix) }
    /// In a walk-through: what right-clicking a thumbnail, or dropping a file on the thumbnails, does.
    var debugThumbnailActions: ThumbnailActions { sidebar.thumbnailActions }
    /// In a walk-through: the number of the page at the top of the view.
    var debugPageAtTop: Int { currentPlace?.page ?? -1 }
    /// In a walk-through: 另存为 without the save panel.
    func debugSaveAs(to target: URL) {
        guard let session = current else { return }
        saveAs(session, to: target)
    }
    func debugDragThumbnail(_ index: Int, toGap gap: Int) -> Bool { sidebar.debugDragThumbnail(index, toGap: gap) }
    func debugPickUpThumbnail(_ index: Int, overGap gap: Int) { sidebar.debugPickUpThumbnail(index, overGap: gap) }
    func debugLetGoOfThumbnail() { sidebar.debugLetGoOfThumbnail() }
    /// In a walk-through: each page's first words and turn.
    var debugPages: String {
        guard let session = current else { return "no document" }
        return (0..<session.document.pageCount).map { index -> String in
            let page = session.document.page(at: index)
            let words = (page?.string ?? "").split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
            return "\(index + 1):\(words.prefix(24))@\(page?.rotation ?? -1)"
        }.joined(separator: " | ") + (session.hasUnsavedChanges ? " (unsaved)" : "")
    }
    var debugOutlineCurrent: String { sidebar.debugOutlineCurrent }

    /// In a walk-through: scrolls the view down by a few points, as a reader's small move would.
    func debugNudge(by points: CGFloat = 4) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + points))
        scrollView.reflectScrolledClipView(clip)
    }

    func debugFollowFirstVisibleLink() -> Bool {
        guard let session = current else { return false }
        let visible = scrollView.contentView.bounds
        for index in canvas.layout.pages(intersecting: visible) {
            for link in session.links(onPage: index) {
                if case .place(let page, let point) = link.target {
                    follow(page: page, point: point)
                    return true
                }
            }
        }
        return false
    }

    /// Turns the magnifier on with the lens at a given spot of the viewport (0…1 in each direction).
    func debugMagnify(atViewportFraction fraction: CGPoint) {
        setMagnifying(true)
        let visible = scrollView.contentView.bounds
        magnifier?.pointerMoved(to: NSPoint(x: visible.minX + visible.width * fraction.x, y: visible.minY + visible.height * fraction.y))
    }

    /// Sends a real right-click event to the middle of the page area, the way the mouse would.
    func debugRightClickOnPage() {
        let visible = canvas.visibleRect
        let inWindow = canvas.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }

    private weak var debugMouseTarget: NSView?

    /// Hands a mouse event to the view under it, as the window would. Run from the command line the
    /// app is not in front, and a window in the background swallows the first click to come forward,
    /// so the window's own routing cannot be used here.
    private func debugSendMouse(_ type: NSEvent.EventType, inWindow point: NSPoint, clicks: Int = 1) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
        if type == .leftMouseDown { debugMouseTarget = window.contentView?.superview?.hitTest(point) }
        guard let target = debugMouseTarget else { return }
        switch type {
        case .leftMouseDown: target.mouseDown(with: event)
        case .leftMouseDragged: target.mouseDragged(with: event)
        case .leftMouseUp: target.mouseUp(with: event)
        default: break
        }
    }

    private func debugSendMouse(_ type: NSEvent.EventType, at canvasPoint: NSPoint, clicks: Int = 1) {
        debugSendMouse(type, inWindow: canvas.convert(canvasPoint, to: nil), clicks: clicks)
    }

    /// The canvas rectangles of the text lines on the pages in view, top to bottom.
    /// The canvas rectangles of the text lines on the pages in view, top to bottom, leaving out lines
    /// with a link on them (clicking those would follow the link), whatever the window's size.
    func debugVisibleLines() -> [CGRect] {
        guard let session = current else { return [] }
        let visible = scrollView.contentView.bounds.insetBy(dx: 0, dy: 60)
        var lines: [CGRect] = []
        for index in canvas.layout.pages(intersecting: visible) {
            guard let page = session.document.page(at: index), let all = page.selection(for: page.bounds(for: .cropBox)) else { continue }
            let links = session.links(onPage: index).map(\.rect)
            for line in all.selectionsByLine() {
                let pageRect = line.bounds(for: page)
                guard !links.contains(where: { $0.intersects(pageRect) }) else { continue }
                let rect = PageGeometry.canvasRect(forPageRect: pageRect, pageFrame: canvas.layout.frames[index], page: page)
                if rect.width > 150, rect.height > 4, visible.contains(rect) { lines.append(rect) }
            }
        }
        return lines
    }

    /// Drags across a line of text with real mouse events, the way a hand would.
    func debugDrag(across line: CGRect) {
        let y = line.midY
        debugSendMouse(.leftMouseDown, at: NSPoint(x: line.minX + 1, y: y))
        for step in 1...8 { debugSendMouse(.leftMouseDragged, at: NSPoint(x: line.minX + 1 + (line.width - 2) * CGFloat(step) / 8, y: y)) }
        debugSendMouse(.leftMouseUp, at: NSPoint(x: line.maxX - 1, y: y))
    }

    func debugClick(at canvasPoint: NSPoint) {
        debugSendMouse(.leftMouseDown, at: canvasPoint)
        debugSendMouse(.leftMouseUp, at: canvasPoint)
    }

    /// Clicks the control in the markup panel with this tooltip (高亮, 下划线, a colour: 黄 红 绿 蓝; 附注, 删除).
    @discardableResult
    func debugClickInMarkupPanel(_ toolTip: String) -> Bool {
        guard let panel = markupPanel else { return false }
        // A panel opened in the same step has not been laid out yet.
        panel.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSView? {
            // Named in English in the walk-throughs, shown in the reader's language.
            if view.toolTip == L(toolTip) { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let control = find(panel) else { return false }
        let centre = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        // A button runs its own tracking loop on mouse-down, which would wait for a real release.
        if let button = control as? NSButton { button.performClick(nil); return true }
        debugSendMouse(.leftMouseDown, inWindow: centre)
        debugSendMouse(.leftMouseUp, inWindow: centre)
        return true
    }

    /// Types a note into the markup panel, if its note area is open.
    func debugMarkupPanel(note: String? = nil) {
        guard let view = markupPanel?.content else { return }
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        if let note, let text = all(view).compactMap({ $0 as? NSTextView }).first { text.string = note }
    }

    /// Clicks the note sign of the first mark in view that has a note.
    @discardableResult
    func debugClickNoteSign() -> Bool {
        guard let session = current else { return false }
        for index in canvas.layout.pages(intersecting: scrollView.contentView.bounds) {
            guard let page = session.document.page(at: index) else { continue }
            for annotation in page.annotations where MarkupEditor.isMark(annotation) && !(annotation.contents ?? "").isEmpty {
                let sign = canvas.noteSignRect(for: annotation, pageFrame: canvas.layout.frames[index], page: page)
                debugClick(at: NSPoint(x: sign.midX, y: sign.midY))
                return true
            }
        }
        return false
    }

    func debugPressDone() {
        guard let view = markupPanel?.content else { return }
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        (all(view).compactMap { $0 as? NSButton }.first { $0.title == L("Done") })?.performClick(nil)
    }

    var debugMarks: String {
        guard let session = current else { return "no document" }
        var parts: [String] = []
        for index in 0..<session.document.pageCount {
            guard let page = session.document.page(at: index) else { continue }
            for annotation in page.annotations where MarkupEditor.isMark(annotation) {
                let c = annotation.color.usingColorSpace(.sRGB) ?? annotation.color
                parts.append("p\(index + 1) \(annotation.type ?? "?") rgb(\(String(format: "%.2f,%.2f,%.2f", c.redComponent, c.greenComponent, c.blueComponent)))"
                             + (annotation.contents.map { " note=\"\($0)\"" } ?? ""))
            }
        }
        return "marks=[\(parts.joined(separator: "; "))] unsaved=\(session.hasUnsavedChanges) saving=\(session.isSaving) panel=\(markupPanel != nil) "
            + "selection=\"\((canvas.selection?.string ?? "").prefix(30))\" edited=\(window.isDocumentEdited) tab=\"\(session.tabTitle.prefix(20))\""
    }

    /// Drags from the start of one line to the end of another.
    func debugDrag(from first: CGRect, to last: CGRect) {
        debugSendMouse(.leftMouseDown, at: NSPoint(x: first.minX + 1, y: first.midY))
        for step in 1...8 {
            let t = CGFloat(step) / 8
            debugSendMouse(.leftMouseDragged, at: NSPoint(x: first.minX + (last.maxX - first.minX) * t, y: first.midY + (last.midY - first.midY) * t))
        }
        debugSendMouse(.leftMouseUp, at: NSPoint(x: last.maxX - 1, y: last.midY))
    }

    /// The selection as ⌘C and ⌥⌘C would put it on the clipboard, without touching the clipboard.
    func debugCopiedText(cleaned: Bool) -> String { selectionText(cleaned: cleaned) ?? "-" }

    /// Asks the spelling dictionary once, as a copy across a hyphenated line end would.
    func debugAskDictionary() -> Bool { ReaderWindowController.isEnglishWord("electrochemical") }

    /// Types a page number and presses Return, as the reader would.
    func debugTypePage(_ text: String) {
        typePageNumber(nil)
        pageField.stringValue = text
        pageNumberTyped(pageField)
    }

    /// The question showing over the window, if any.
    var debugSheet: String {
        guard let sheet = window.attachedSheet else { return "none" }
        let texts = sheet.contentView.map { view -> [String] in
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            return all(view).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
        } ?? []
        return texts.joined(separator: " | ")
    }

    /// Answers the question showing over the window with its first button (1) or second (2).
    func debugAnswerSheet(_ button: Int) {
        guard let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: button == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }

    var debugFile: String {
        guard let session = current else { return "-" }
        return "file=\(session.url.lastPathComponent) title=\(window.title) proxy=\(window.representedURL?.lastPathComponent ?? "none")"
    }

    func debugDismissOverlays() {
        links?.dismiss()
        setMagnifying(false)
    }

    var debugOverlays: String {
        "preview=\(links?.isShowingPreview ?? false) lens=\(magnifier?.isShowingLens ?? false) "
            + "back=\(current?.history.canGoBack ?? false) forward=\(current?.history.canGoForward ?? false)"
    }

    /// One line describing what the window is showing, for the benchmark's log.
    var debugSummary: String {
        let top = canvas.layout.anchor(at: scrollView.contentView.bounds.origin)
        return "tabs=\(sessions.count) selected=\(selectedIndex) title=\"\(window.title.prefix(24))\" "
            + "page=\"\(pageField.stringValue) \(pageTotal.stringValue)\" scale=\(String(format: "%.3f", current?.scale ?? 0)) "
            + "top=\(top.map { "p\($0.page + 1) x\(String(format: "%.2f", $0.x)) y\(String(format: "%.2f", $0.y))" } ?? "-") "
            + "strip=\(Int(tabStripHeight?.constant ?? 0))"
    }

    // MARK: Zoom

    /// Changes the scale while keeping the same spot of the page under `viewportPoint`
    /// (measured from the viewport's top-left corner; its middle when nil).
    private func setScale(_ scale: CGFloat?, fitsWidth: Bool, around viewportPoint: CGPoint? = nil) {
        guard let session = current else { return }
        let clip = scrollView.contentView
        let offset = viewportPoint ?? CGPoint(x: clip.bounds.width / 2, y: clip.bounds.height / 2)
        let anchor = canvas.layout.anchor(at: CGPoint(x: clip.bounds.minX + offset.x, y: clip.bounds.minY + offset.y))
        session.fitsWidth = fitsWidth
        if let scale { session.scale = Zoom.clamped(scale) }
        display(session, keeping: anchor, at: offset)
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let session = current else { return }
        setScale(session.scale * Zoom.step, fitsWidth: false)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let session = current else { return }
        setScale(session.scale / Zoom.step, fitsWidth: false)
    }

    @objc func zoomToFitWidth(_ sender: Any?) {
        setScale(nil, fitsWidth: true)
    }

    /// Pinch: the spot under the fingers stays under the fingers.
    private func magnify(by change: CGFloat, at canvasPoint: NSPoint) {
        guard let session = current else { return }
        let origin = scrollView.contentView.bounds.origin
        setScale(session.scale * (1 + change), fitsWidth: false,
                 around: CGPoint(x: canvasPoint.x - origin.x, y: canvasPoint.y - origin.y))
    }
}
