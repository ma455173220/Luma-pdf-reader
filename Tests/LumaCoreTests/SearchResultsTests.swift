import XCTest
@testable import LumaCore

final class SearchResultsTests: XCTestCase {
    private func results(onPages pages: [Int]) -> SearchResults {
        var results = SearchResults()
        for (index, page) in pages.enumerated() {
            results.append(SearchMatch(page: page, rects: [CGRect(x: CGFloat(index), y: 0, width: 10, height: 10)]))
        }
        return results
    }

    func testNothingFound() {
        var results = SearchResults()
        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(results.currentMatch)
        XCTAssertEqual(results.label(isSearching: false), "无结果")
        XCTAssertEqual(results.label(isSearching: true), "查找中…")
        results.selectNext()
        results.selectPrevious()
        results.selectFirst(fromPage: 3)
        XCTAssertNil(results.current)
    }

    func testStartsFromWhereTheReaderIs() {
        var results = results(onPages: [0, 0, 2, 5, 5, 9])
        results.selectFirst(fromPage: 3)
        XCTAssertEqual(results.current, 3, "the first match on page 4 or later")
        results.selectFirst(fromPage: 0)
        XCTAssertEqual(results.current, 0)
    }

    func testStartsFromTheTopWhenNothingLiesAhead() {
        var results = results(onPages: [0, 1])
        results.selectFirst(fromPage: 7)
        XCTAssertEqual(results.current, 0)
    }

    func testSettlesOnTheFirstMatchAheadAsSoonAsItArrives() {
        var results = SearchResults()
        results.append(SearchMatch(page: 1, rects: []))
        XCTAssertFalse(results.selectNewestIfFirstAhead(ofPage: 4), "behind the reader: keep waiting")
        results.append(SearchMatch(page: 6, rects: []))
        XCTAssertTrue(results.selectNewestIfFirstAhead(ofPage: 4))
        XCTAssertEqual(results.current, 1)
        results.append(SearchMatch(page: 8, rects: []))
        XCTAssertFalse(results.selectNewestIfFirstAhead(ofPage: 4), "already settled; later matches do not move it")
        XCTAssertEqual(results.current, 1)
    }

    func testNextAndPreviousGoRound() {
        var results = results(onPages: [0, 1, 2])
        results.selectFirst(fromPage: 0)
        results.selectNext()
        XCTAssertEqual(results.current, 1)
        results.selectNext()
        results.selectNext()
        XCTAssertEqual(results.current, 0, "after the last comes the first")
        results.selectPrevious()
        XCTAssertEqual(results.current, 2, "before the first comes the last")
    }

    func testLabelCountsFromOne() {
        var results = results(onPages: [0, 1, 2])
        results.selectFirst(fromPage: 1)
        XCTAssertEqual(results.label(isSearching: false), "2 / 3")
        XCTAssertEqual(results.label(isSearching: true), "2 / 3…", "more may still be coming")
    }

    func testRectanglesOfOnePage() {
        let results = results(onPages: [0, 2, 2, 2, 7])
        XCTAssertEqual(results.rects(onPage: 2).map(\.minX), [1, 2, 3])
        XCTAssertEqual(results.rects(onPage: 0).count, 1)
        XCTAssertTrue(results.rects(onPage: 1).isEmpty)
        XCTAssertTrue(results.rects(onPage: 99).isEmpty)
        XCTAssertTrue(SearchResults().rects(onPage: 0).isEmpty)
    }

    func testAMatchOverSeveralLinesKeepsAllItsRectangles() {
        var results = SearchResults()
        results.append(SearchMatch(page: 4, rects: [CGRect(x: 0, y: 20, width: 50, height: 10), CGRect(x: 0, y: 8, width: 30, height: 10)]))
        XCTAssertEqual(results.rects(onPage: 4).count, 2)
    }

    func testSearchStopsAtItsLimit() {
        var results = SearchResults()
        for index in 0..<SearchResults.limit { XCTAssertTrue(results.append(SearchMatch(page: index / 10, rects: []))) }
        XCTAssertFalse(results.isTruncated)
        XCTAssertFalse(results.append(SearchMatch(page: 999, rects: [])), "the caller is told to stop")
        XCTAssertTrue(results.isTruncated)
        XCTAssertEqual(results.matches.count, SearchResults.limit)
        results.selectFirst(fromPage: 0)
        XCTAssertEqual(results.label(isSearching: false), "1 / \(SearchResults.limit)+")
    }
}
