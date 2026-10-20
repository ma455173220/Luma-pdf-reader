import Foundation
import LumaCore
import PDFKit

/// One open document and where the reader is in it.
///
/// A session in a background tab holds only this: the document and a few numbers. It keeps no
/// page images, which is what lets many tabs stay open cheaply.
final class DocumentSession {
    let url: URL
    let document: PDFDocument
    private(set) var pageSizes: [CGSize]
    /// A sleeping tab: the document has been let go to save memory, and is read again when the tab is
    /// shown. Only the few numbers below that say where the reader was are kept (ADR 0005).
    let isAsleep: Bool
    /// When the tab was last in front, for deciding when it may sleep.
    var lastShown = Date()
    /// A sleeping tab whose file could not be read when it was last chosen: shown empty until chosen again.
    var couldNotWake = false
    /// The document asked for a password to be opened (not one only to restrict printing or editing,
    /// which many journal PDFs carry and which opens without asking). Such a tab never sleeps: waking
    /// it would ask again.
    var neededPassword = false
    /// What a sleeping session stands in for the document with: no pages, nothing held.
    private static let nothing = PDFDocument()

    var scale: CGFloat = 1
    /// While true the scale follows the window width.
    var fitsWidth = true
    /// What was at the top-left of the viewport when this tab was last on screen.
    var position: PageLayout.Anchor?
    /// The reader's marks and what saving has to write.
    private(set) lazy var markup = MarkupEditor(session: self)
    /// The reader's page edits and what saving has to write.
    private(set) lazy var pages = PageEditor(session: self)
    /// Why marks could not be saved into this file, found when it was opened; nil when they can.
    var markupBlockedBy: PDFAppendError?
    /// Whether the check that sets `markupBlockedBy` has been made for this file as read.
    var markupChecked = false
    /// The file's size and modification time when it was opened (before reading it) or last saved.
    /// Saving refuses if another program has changed the file since.
    var fileStamp: FileStamp?
    /// A save is under way; marks cannot be changed until it ends.
    var isSaving = false
    struct FileStamp: Equatable {
        let size: Int
        let modified: Date

        /// The stamp of the file itself, following a link to it. Read afresh every time: a URL
        /// keeps the values it has read, and saving compares two readings taken moments apart.
        static func of(_ url: URL) -> FileStamp? {
            var file = url.resolvingSymlinksInPath()
            file.removeAllCachedResourceValues()
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            return FileStamp(size: size, modified: modified)
        }
    }

    var hasUnsavedChanges: Bool { markup.hasUnsavedChanges || pages.hasUnsavedChanges }

    /// After page edits were saved but the file could not be read again: what was worked out from the
    /// file before the edits names pages that have moved, so it is not shown any more.
    func forgetWhatWasWorkedOut() {
        decoding = .none
        workedOutOutline = []
        linkCache = [:]
    }

    /// After a page edit: the pages' sizes, links, outline and places to go back to are found afresh.
    /// While page edits are unsaved, nothing worked out from the file is shown, since the file's pages
    /// are no longer the ones shown: no inferred links, no inferred outline.
    func pagesChanged() {
        pageSizes = (0..<document.pageCount).map { index in
            document.page(at: index).map(PageRenderer.displaySize(of:)) ?? CGSize(width: 612, height: 792)
        }
        linkCache = [:]
        ownOutlineCache = nil
        collapsedOutlineEntries = DocumentOutline.initiallyCollapsed(outline)
        history = NavigationHistory<PageLayout.Anchor>()
    }

    /// Places the reader jumped away from, for going back.
    var history = NavigationHistory<PageLayout.Anchor>()
    /// Links found so far, by page. Read from the document the first time the pointer visits a page.
    private var linkCache: [Int: [PageLink]] = [:]

    /// The outline the document carries, read the first time the sidebar asks for it, and again after a page edit.
    private var ownOutlineCache: [OutlineEntry]?
    private var ownOutline: [OutlineEntry] {
        if let cached = ownOutlineCache { return cached }
        let entries = DocumentOutline.entries(of: document)
        ownOutlineCache = entries
        return entries
    }
    /// The outline to show: the document's own, or failing that, one worked out from its text once
    /// that is ready (see `workOutOutline`).
    var outline: [OutlineEntry] {
        guard ownOutline.isEmpty else { return ownOutline }
        // Worked out from the file, it names the file's pages, which page edits have moved.
        return pages.hasUnsavedChanges ? [] : workedOutOutline ?? []
    }
    /// The outline entries the reader has folded shut. Starts with the top two levels open.
    lazy var collapsedOutlineEntries: Set<Int> = DocumentOutline.initiallyCollapsed(outline)

    private var workedOutOutline: [OutlineEntry]?
    private var outlineWaiters: [() -> Void] = []
    /// Whether an outline is being worked out from the text right now.
    var isWorkingOutOutline: Bool { !outlineWaiters.isEmpty }
    /// Whether the outline shown was worked out from the text, not carried by the document.
    var outlineIsWorkedOut: Bool { ownOutline.isEmpty && !(workedOutOutline ?? []).isEmpty }

    private var outlineJob: OutlineProcess.Job?
    private var outlineAttempts = 0

    /// For a document without an outline of its own, works one out from its text, once, in a helper
    /// process; `ready` is called when it is done. Nothing happens for a document with its own. The
    /// helper reads the file afresh, so its answer is taken only if the file is still the one shown.
    func workOutOutline(ready: @escaping () -> Void) {
        guard ownOutline.isEmpty, workedOutOutline == nil, !pages.hasUnsavedChanges else { return }
        outlineWaiters.append(ready)
        guard outlineWaiters.count == 1 else { return }
        let file = url.resolvingSymlinksInPath()
        let stamp = fileStamp
        outlineJob = OutlineProcess.start(for: file, pageCount: document.pageCount) { [weak self] entries in
            guard let self else { return }
            self.outlineJob = nil
            let unchanged = stamp == nil || (FileStamp.of(file) == stamp && self.fileStamp == stamp)
            // A file changed meanwhile (by a sync service, another program, or a save): asked once more
            // the next time the outline is shown, then left without.
            self.outlineAttempts += 1
            self.workedOutOutline = unchanged ? entries : self.outlineAttempts < 2 ? nil : []
            self.collapsedOutlineEntries = DocumentOutline.initiallyCollapsed(self.outline)
            let waiters = self.outlineWaiters
            self.outlineWaiters = []
            waiters.forEach { $0() }
        }
    }

    deinit { outlineJob?.cancel() }

    /// The links on a page: the document's own, and, where it has none, those worked out from its
    /// citations and its references to figures and tables. Working them out starts the first time
    /// links are asked for; until it is ready, only the document's own are given.
    func links(onPage index: Int) -> [PageLink] {
        if let cached = linkCache[index] { return cached }
        let own = document.page(at: index).map { PageLinks.links(on: $0, in: document) } ?? []
        // Links worked out from the text name the file's pages, which page edits have moved.
        if pages.hasUnsavedChanges {
            linkCache[index] = own
            return own
        }
        var found = own
        switch decoding {
        case .ready(let citations, let figures):
            found += citations?.links(onPage: index, besides: own) ?? []
            found += figures.pendingLinks(onPage: index, besides: found)
        case .none: break
        case .notStarted, .preparing:
            prepareDecoding()
            return own   // asked again once ready
        }
        linkCache[index] = found
        return found
    }

    /// A link from `links(onPage:)` ready to use: a reference to a figure or table gets the place it
    /// leads to, found now; nil when there is none.
    func resolved(_ link: PageLink, onPage index: Int) -> PageLink? {
        guard case .figure = link.target else { return link }
        guard case .ready(_, let figures) = decoding else { return nil }
        return figures.resolved(link, onPage: index)
    }

    /// The type size of the running text, once decoding was prepared: for telling a caption from a
    /// line of the body when a preview looks for one (ADR 0006).
    private(set) var bodySize: CGFloat?

    /// A document of the session's own for reading text from, so that the text read does not stay
    /// with the document shown: for the figures of a document that links its own citations, and for
    /// the text in previews (ADR 0006). Let go of after `TextReader.keptFor` unused, and on sleeping.
    private(set) lazy var textReader: TextReader = {
        let file = url.resolvingSymlinksInPath()
        return TextReader(file: file, pageCount: document.pageCount) { [weak self] in
            // Changed on disk since it was read (not by saving, which reads it again): not read.
            guard let known = self?.fileStamp else { return true }
            return DocumentSession.FileStamp.of(file) == known
        }
    }()

    /// For walk-throughs: whether figures are read from a document of the decoder's own just now.
    var debugFigureReadingHeld: Bool { textReader.isHolding }

    /// For tests: where working out links stands.
    var debugDecoding: String {
        switch decoding {
        case .notStarted: return "not started"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .none: return "none"
        }
    }

    private enum Decoding {
        /// Citations are not worked out for a document that links its own (nil).
        case notStarted, preparing, ready(CitationDecoder?, FigureDecoder), none
    }
    /// Links worked out from the text, once what decoding needs to know about the document is read.
    private var decoding = Decoding.notStarted

    /// Reads the reference list and the size of the running text in the background, from the file
    /// itself, so that the window does not wait. A document that needed a password is not read again:
    /// the password is not kept.
    private func prepareDecoding() {
        guard case .notStarted = decoding, !pages.hasUnsavedChanges else { return }
        // Read afresh from a file that has not changed (woken, or read again when idle): what was
        // prepared before still holds (ADR 0006).
        if let carried = carriedPreparation, CitationDecoder.fits(carried, document) {
            carriedPreparation = nil
            use(carried)
            return
        }
        decoding = .preparing
        let file = url.resolvingSymlinksInPath()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let preparation = CitationDecoder.prepare(fileAt: file)
            DispatchQueue.main.async {
                guard let self else { return }
                // Pages were edited meanwhile: the file's pages are not the ones shown. Tried again
                // once the edits are saved or undone.
                if self.pages.hasUnsavedChanges {
                    self.decoding = .notStarted
                } else if let preparation, CitationDecoder.fits(preparation, self.document) {
                    self.use(preparation)
                } else {
                    self.decoding = .none
                    self.linkCache = [:]
                }
            }
        }
    }

    /// What decoding needs to know, once read from the file; kept so that reading the same file afresh
    /// need not read it again.
    private var preparation: CitationDecoder.Preparation?
    /// Handed over from the session this one was read afresh from, the file unchanged.
    var carriedPreparation: CitationDecoder.Preparation?

    private func use(_ preparation: CitationDecoder.Preparation) {
        self.preparation = preparation
        bodySize = preparation.bodySize
        // LUMA_FIGURES_FROM_SHOWN: a walk-through's comparison, reading the document shown instead.
        if preparation.linksItsOwnCitations, ProcessInfo.processInfo.environment["LUMA_FIGURES_FROM_SHOWN"] == nil {
            // Its figures are read from a document of the decoder's own, let go of between uses.
            decoding = .ready(nil, FigureDecoder(reading: textReader, pageCount: document.pageCount, bodySize: preparation.bodySize))
        } else if preparation.linksItsOwnCitations {
            decoding = .ready(nil, FigureDecoder(document: document, bodySize: preparation.bodySize))
        } else {
            decoding = .ready(CitationDecoder(document: document, preparation: preparation),
                              FigureDecoder(document: document, bodySize: preparation.bodySize))
        }
        linkCache = [:]
    }

    init(url: URL, document: PDFDocument) {
        self.url = url
        self.document = document
        self.isAsleep = false
        self.pageSizes = (0..<document.pageCount).map { index in
            document.page(at: index).map(PageRenderer.displaySize(of:)) ?? CGSize(width: 612, height: 792)
        }
    }

    private init(asleep url: URL) {
        self.url = url
        self.document = DocumentSession.nothing
        self.isAsleep = true
        self.pageSizes = []
    }

    // MARK: Sleeping

    /// Whether this tab may be put to sleep now: nothing unsaved, nothing to undo or redo (sleeping
    /// would lose it), no save under way, and no password asked for on opening (waking would ask again).
    var maySleep: Bool {
        !isAsleep && !isSaving && !hasUnsavedChanges && !markup.undoManager.canUndo && !markup.undoManager.canRedo
            && !neededPassword && document.pageCount > 0
    }

    /// The same tab asleep: where the reader was, and nothing else. The document goes with this session.
    func asleep() -> DocumentSession {
        let sleeping = DocumentSession(asleep: url)
        carry(to: sleeping)
        outlineJob?.cancel()
        return sleeping
    }

    /// Hands what says where the reader was to the session that takes this one's place: on going to
    /// sleep, and on waking up.
    /// `fileChanged`: the file was changed by another program while the tab slept, so places to go
    /// back to and an outline worked out from the old file no longer fit; they are not carried.
    func carry(to other: DocumentSession, fileChanged: Bool = false) {
        other.scale = scale
        other.fitsWidth = fitsWidth
        other.lastShown = lastShown
        if let position, position.page < max(1, other.isAsleep ? Int.max : other.document.pageCount) {
            other.position = position
        } else if position != nil {
            other.position = PageLayout.Anchor(page: max(0, other.document.pageCount - 1))
        }
        guard !fileChanged else { return }
        other.fileStamp = fileStamp
        // The same file: whether marks can be saved into it, and what decoding needs to know, still hold.
        if markupChecked {
            other.markupBlockedBy = markupBlockedBy
            other.markupChecked = true
        }
        other.carriedPreparation = preparation ?? carriedPreparation
        other.history = history
        other.workedOutOutline = workedOutOutline
        other.outlineAttempts = outlineAttempts
        other.collapsedOutlineEntries = collapsedOutlineEntries
    }

    var title: String { url.deletingPathExtension().lastPathComponent }
    /// The tab's label: a dot in front while there are unsaved marks.
    var tabTitle: String { (hasUnsavedChanges ? "• " : "") + title }
}
