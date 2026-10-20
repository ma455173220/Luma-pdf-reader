import CoreGraphics
import Foundation

/// One place where the searched text occurs.
public struct SearchMatch: Equatable {
    public let page: Int
    /// One rectangle per line the match runs over, in page coordinates.
    public let rects: [CGRect]

    public init(page: Int, rects: [CGRect]) {
        self.page = page
        self.rects = rects
    }
}

/// The matches of a search and which of them the reader is on. Matches are kept in reading order.
public struct SearchResults: Equatable {
    /// More than this is no help to a reader and only costs memory.
    public static let limit = 5000

    public private(set) var matches: [SearchMatch] = []
    public private(set) var current: Int?
    /// True when the search stopped at `limit` with more left unfound.
    public private(set) var isTruncated = false

    public init() {}

    public var isEmpty: Bool { matches.isEmpty }
    public var currentMatch: SearchMatch? { current.map { matches[$0] } }

    /// Adds a match as it is found. Returns false once the limit is reached; the search should stop.
    @discardableResult
    public mutating func append(_ match: SearchMatch) -> Bool {
        guard matches.count < SearchResults.limit else {
            isTruncated = true
            return false
        }
        matches.append(match)
        return true
    }

    /// Starts from where the reader is: the first match on that page or later, or failing that
    /// the very first one.
    public mutating func selectFirst(fromPage page: Int) {
        guard !matches.isEmpty else {
            current = nil
            return
        }
        current = matches.firstIndex { $0.page >= page } ?? 0
    }

    /// While matches are still arriving: settles on the newest one if it is the first to lie on the
    /// reader's page or later, so that the view can move there without waiting for the search to end.
    /// Returns true if it did.
    public mutating func selectNewestIfFirstAhead(ofPage page: Int) -> Bool {
        guard current == nil, let newest = matches.last, newest.page >= page else { return false }
        current = matches.count - 1
        return true
    }

    /// Moves to the next match, going round to the first after the last.
    public mutating func selectNext() {
        guard !matches.isEmpty else { return }
        current = ((current ?? -1) + 1) % matches.count
    }

    public mutating func selectPrevious() {
        guard !matches.isEmpty else { return }
        current = ((current ?? 0) + matches.count - 1) % matches.count
    }

    /// The rectangles to mark on one page, for painting.
    public func rects(onPage page: Int) -> [CGRect] {
        guard !matches.isEmpty else { return [] }
        // Matches are in page order, so the ones for a page sit together.
        var low = 0, high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].page < page { low = middle + 1 } else { high = middle }
        }
        var found: [CGRect] = []
        while low < matches.count && matches[low].page == page {
            found += matches[low].rects
            low += 1
        }
        return found
    }

    /// What the search bar shows beside the field.
    public func label(isSearching: Bool) -> String {
        if matches.isEmpty { return isSearching ? "查找中…" : "无结果" }
        let total = isTruncated ? "\(matches.count)+" : (isSearching ? "\(matches.count)…" : "\(matches.count)")
        return "\((current ?? 0) + 1) / \(total)"
    }
}

/// How a search matches: the reader's two choices in the find bar.
public struct SearchOptions: Equatable {
    public var matchCase: Bool
    public var wholeWords: Bool

    public init(matchCase: Bool = false, wholeWords: Bool = false) {
        self.matchCase = matchCase
        self.wholeWords = wholeWords
    }

    /// Whether a match stands as a whole word: the characters on either side of it (nil at the start
    /// or end of the text) are not letters or digits. A side of the match that is not a letter or
    /// digit itself ("Cu-") needs nothing of its neighbour there.
    public static func isWholeWord(_ match: String, before: Character?, after: Character?) -> Bool {
        func wordy(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
        let starts = match.first.map { wordy($0) } ?? false, ends = match.last.map { wordy($0) } ?? false
        return !(starts && wordy(before)) && !(ends && wordy(after))
    }
}

