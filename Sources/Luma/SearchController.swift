import AppKit
import LumaCore
import PDFKit

/// Runs a search through one document and keeps its results.
///
/// The pages are read a few at a time between the reader's own events, so the window stays
/// responsive; what is kept of each match is only its page and its rectangles. The text is matched
/// as it reads (`TextSearch`), so a phrase running onto the next line, or a word hyphenated at a line
/// break, is found too, which the system's own search does not do.
final class SearchController: NSObject {
    private(set) var results = SearchResults()
    private(set) var isSearching = false
    /// Called whenever the results change. `settled` is true when the match the reader is on has
    /// just been chosen or changed, which is when the view should go to it.
    var onChange: ((_ settled: Bool) -> Void)?

    private var document: PDFDocument?
    private var startPage = 0
    private var nextPage = 0
    private var options = SearchOptions()
    private var query = ""
    /// Counts searches, so that a slice of pages queued for an earlier one does nothing.
    private var generation = 0

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
        nextPage = 0
        isSearching = true
        onChange?(false)
        scheduleSlice()
    }

    /// Stops any search under way and forgets its results.
    func cancel() {
        generation += 1
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

    private func scheduleSlice() {
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.searchSlice()
        }
    }

    /// Reads pages for a few milliseconds, then lets the reader's events through before the next ones.
    private func searchSlice() {
        guard isSearching, let document else { return }
        let until = Date(timeIntervalSinceNow: 0.008)
        var settled = false, changed = false
        while nextPage < document.pageCount {
            let index = nextPage
            nextPage += 1
            guard let page = document.page(at: index) else { continue }
            let text = autoreleasepool { page.string ?? "" }
            for range in TextSearch.ranges(of: query, in: text, options: options) {
                let rects = autoreleasepool {
                    page.selection(for: range)?.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty } ?? []
                }
                guard !rects.isEmpty else { continue }
                guard results.append(SearchMatch(page: index, rects: rects)) else {
                    // Enough. More matches would not help the reader and only cost memory.
                    nextPage = document.pageCount
                    break
                }
                changed = true
                if results.selectNewestIfFirstAhead(ofPage: startPage) { settled = true }
            }
            if Date() >= until { break }
        }
        if nextPage < document.pageCount {
            if changed { onChange?(settled) }
            scheduleSlice()
            return
        }
        isSearching = false
        // Nothing lay ahead of the reader: start from the top instead.
        if results.current == nil && !results.isEmpty {
            results.selectFirst(fromPage: startPage)
            settled = true
        }
        onChange?(settled)
    }
}
