import AppKit
import LumaCore
import PDFKit

/// Runs a search through one document and keeps its results.
///
/// The system engine does the searching in the background and reports matches one by one; what is
/// kept of each is only its page and its rectangles, not the engine's own selection objects.
final class SearchController: NSObject {
    private(set) var results = SearchResults()
    private(set) var isSearching = false
    /// Called whenever the results change. `settled` is true when the match the reader is on has
    /// just been chosen or changed, which is when the view should go to it.
    var onChange: ((_ settled: Bool) -> Void)?

    private var document: PDFDocument?
    private var startPage = 0
    private var options = SearchOptions()
    private var query = ""

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start(_ query: String, in document: PDFDocument, fromPage page: Int, options: SearchOptions = SearchOptions()) {
        cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            onChange?(false)
            return
        }
        self.document = document
        self.options = options
        self.query = text
        startPage = page
        isSearching = true
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(found(_:)), name: .PDFDocumentDidFindMatch, object: document)
        centre.addObserver(self, selector: #selector(ended(_:)), name: .PDFDocumentDidEndFind, object: document)
        document.beginFindString(text, withOptions: options.matchCase ? [.diacriticInsensitive] : [.caseInsensitive, .diacriticInsensitive])
        onChange?(false)
    }

    /// Stops any search under way and forgets its results.
    func cancel() {
        if let document {
            NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidFindMatch, object: document)
            NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidEndFind, object: document)
            if document.isFinding { document.cancelFindString() }
        }
        document = nil
        isSearching = false
        results = SearchResults()
    }

    func selectNext() {
        results.selectNext()
        onChange?(true)
    }

    func selectPrevious() {
        results.selectPrevious()
        onChange?(true)
    }

    @objc private func found(_ notification: Notification) {
        guard let document, let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
              let page = selection.pages.first else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        // Whole words only: the engine finds the text inside longer words too; those are passed over,
        // judged by the characters either side (one more each way, on the match's own lines).
        if options.wholeWords, let start = selection.copy() as? PDFSelection, let end = selection.copy() as? PDFSelection {
            let own = selection.string ?? query
            start.extend(atStart: 1)
            end.extend(atEnd: 1)
            let before = (start.string?.count ?? 0) > own.count ? start.string?.first : nil
            let after = (end.string?.count ?? 0) > own.count ? end.string?.last : nil
            guard SearchOptions.isWholeWord(own, before: before, after: after) else { return }
        }
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        guard results.append(SearchMatch(page: index, rects: rects)) else {
            // Enough. More matches would not help the reader and only cost memory.
            document.cancelFindString()
            return
        }
        onChange?(results.selectNewestIfFirstAhead(ofPage: startPage))
    }

    @objc private func ended(_ notification: Notification) {
        guard isSearching else { return }
        isSearching = false
        // Nothing lay ahead of the reader: start from the top instead.
        let settledNow = results.current == nil && !results.isEmpty
        if settledNow { results.selectFirst(fromPage: startPage) }
        onChange?(settledNow)
    }
}
