import XCTest
@testable import LumaCore

final class PageLayoutTests: XCTestCase {
    private let letter = CGSize(width: 612, height: 792)
    /// A4 in points. Its fractional size is what real documents have, and what whole-number tests miss.
    private let a4 = CGSize(width: 595.276, height: 841.89)

    /// A small deterministic random source, so that a failing case can be reproduced.
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func between(_ low: Double, _ high: Double) -> CGFloat { CGFloat(low + (high - low) * next()) }
    }

    func testPagesStackInOneColumnWithGaps() {
        let layout = PageLayout(pageSizes: [letter, letter, letter], scale: 1, viewportWidth: 800)
        XCTAssertEqual(layout.frames.count, 3)
        XCTAssertEqual(layout.frames[0].minY, PageLayout.gap)
        XCTAssertEqual(layout.frames[1].minY, layout.frames[0].maxY + PageLayout.gap)
        XCTAssertEqual(layout.contentSize.height, layout.frames[2].maxY + PageLayout.gap)
        XCTAssertEqual(layout.contentSize.width, 800)
    }

    func testPagesAreCentredAndNarrowPagesToo() {
        let narrow = CGSize(width: 300, height: 400)
        let layout = PageLayout(pageSizes: [letter, narrow], scale: 1, viewportWidth: 1000)
        XCTAssertEqual(layout.frames[0].midX, 500, accuracy: 1)
        XCTAssertEqual(layout.frames[1].midX, 500, accuracy: 1)
    }

    func testContentGrowsWiderThanViewportWhenZoomedIn() {
        let layout = PageLayout(pageSizes: [letter], scale: 2, viewportWidth: 800)
        XCTAssertEqual(layout.contentSize.width, 612 * 2 + 2 * PageLayout.gap)
        XCTAssertEqual(layout.frames[0].minX, PageLayout.gap)
    }

    func testPagesNeverOverlapWithFractionalSizes() {
        var random = Random(state: 7)
        for _ in 0..<200 {
            let sizes = (0..<Int(random.between(1, 30))).map { _ in CGSize(width: random.between(100, 900), height: random.between(100, 1300)) }
            let layout = PageLayout(pageSizes: sizes, scale: random.between(0.25, 8), viewportWidth: random.between(200, 2500))
            for (upper, lower) in zip(layout.frames, layout.frames.dropFirst()) {
                XCTAssertGreaterThan(lower.minY, upper.maxY, "a page must start below the end of the one before it")
            }
        }
    }

    func testZeroSizedPagesAndEmptyDocumentsDoNotBreakAnything() {
        let layout = PageLayout(pageSizes: [.zero, letter, .zero], scale: 1, viewportWidth: 800)
        XCTAssertEqual(layout.frames.count, 3)
        XCTAssertEqual(layout.anchor(at: CGPoint(x: 10, y: layout.frames[0].minY))?.page, 0)
        XCTAssertEqual(layout.point(for: PageLayout.Anchor(page: 0, x: 0.5, y: 0.5)), CGPoint(x: layout.frames[0].minX, y: layout.frames[0].minY))
        let empty = PageLayout(pageSizes: [], scale: 1, viewportWidth: 800)
        XCTAssertNil(empty.pageIndex(atY: 0))
        XCTAssertNil(empty.anchor(at: .zero))
        XCTAssertEqual(empty.point(for: PageLayout.Anchor(page: 0)), .zero)
        XCTAssertTrue(empty.pages(intersecting: CGRect(x: 0, y: 0, width: 800, height: 800)).isEmpty)
    }

    func testViewportNarrowerThanTheMarginsStillLaysOut() {
        let layout = PageLayout(pageSizes: [a4], scale: 1, viewportWidth: 10)
        XCTAssertEqual(layout.contentSize.width, a4.width + 2 * PageLayout.gap, accuracy: 0.001)
        XCTAssertEqual(PageLayout.fitWidthScale(pageSizes: [a4], viewportWidth: 10), Zoom.fitMinimum)
    }

    // MARK: Fit width

    func testFitWidthFillsTheViewportWithTheWidestPage() {
        let wide = CGSize(width: 1000, height: 500)
        let scale = PageLayout.fitWidthScale(pageSizes: [a4, wide], viewportWidth: 1024)
        XCTAssertEqual(scale, (1024 - 2 * PageLayout.gap) / 1000, accuracy: 0.0001)
        let layout = PageLayout(pageSizes: [a4, wide], scale: scale, viewportWidth: 1024)
        XCTAssertEqual(layout.frames[1].width, 1024 - 2 * PageLayout.gap, accuracy: 0.01)
        XCTAssertEqual(layout.contentSize.width, 1024, accuracy: 0.01)
    }

    func testFitWidthReachesBelowTheZoomButtonsForVeryWidePages() {
        // An A0 poster in a 600-point window needs about 0.17; the zoom buttons stop at 0.25.
        let poster = CGSize(width: 3370, height: 2384)
        let scale = PageLayout.fitWidthScale(pageSizes: [poster], viewportWidth: 600)
        XCTAssertLessThan(scale, Zoom.minimum)
        XCTAssertLessThanOrEqual(PageLayout(pageSizes: [poster], scale: scale, viewportWidth: 600).contentSize.width, 600.001)
    }

    func testFitWidthHasLimits() {
        XCTAssertEqual(PageLayout.fitWidthScale(pageSizes: [letter], viewportWidth: 20), Zoom.fitMinimum)
        XCTAssertEqual(PageLayout.fitWidthScale(pageSizes: [letter], viewportWidth: 100_000), Zoom.maximum)
        XCTAssertEqual(PageLayout.fitWidthScale(pageSizes: [], viewportWidth: 800), 1)
        XCTAssertEqual(PageLayout.fitWidthScale(pageSizes: [.zero], viewportWidth: 800), 1)
    }

    // MARK: Which page is where

    func testEveryHeightBelongsToExactlyOnePage() {
        let layout = PageLayout(pageSizes: [a4, a4, a4], scale: 1.37, viewportWidth: 800)
        XCTAssertEqual(layout.pageIndex(atY: -50), 0)
        XCTAssertEqual(layout.pageIndex(atY: layout.frames[0].midY), 0)
        XCTAssertEqual(layout.pageIndex(atY: layout.frames[0].maxY + 1), 0, "the gap after a page belongs to it")
        XCTAssertEqual(layout.pageIndex(atY: layout.frames[1].minY), 1, "a page's own top edge belongs to it")
        XCTAssertEqual(layout.pageIndex(atY: layout.frames[1].minY - 0.001), 0)
        XCTAssertEqual(layout.pageIndex(atY: layout.frames[2].maxY + 500), 2)
    }

    /// The rule, checked against a plain search on many random layouts with fractional sizes.
    func testPageOwnershipMatchesItsDefinition() {
        var random = Random(state: 11)
        for _ in 0..<300 {
            let sizes = (0..<Int(random.between(1, 40))).map { _ in CGSize(width: random.between(100, 900), height: random.between(50, 1300)) }
            let layout = PageLayout(pageSizes: sizes, scale: random.between(0.25, 8), viewportWidth: random.between(200, 2500))
            for _ in 0..<40 {
                let y = random.between(-200, Double(layout.contentSize.height) + 200)
                let expected = layout.frames.lastIndex { $0.minY <= y } ?? 0
                XCTAssertEqual(layout.pageIndex(atY: y), expected)
            }
            // Every page's own top edge, exactly: the case whole-number sizes never exercise.
            for (index, frame) in layout.frames.enumerated() { XCTAssertEqual(layout.pageIndex(atY: frame.minY), index) }
        }
    }

    func testPagesIntersectingARectangle() {
        let layout = PageLayout(pageSizes: [letter, letter, letter], scale: 1, viewportWidth: 800)
        let spanning = CGRect(x: 0, y: layout.frames[0].midY, width: 800, height: 792)
        XCTAssertEqual(layout.pages(intersecting: spanning), 0..<2)
        let insideGap = CGRect(x: 0, y: layout.frames[0].maxY + 2, width: 800, height: 4)
        XCTAssertTrue(layout.pages(intersecting: insideGap).isEmpty)
        let below = CGRect(x: 0, y: layout.contentSize.height + 100, width: 800, height: 50)
        XCTAssertTrue(layout.pages(intersecting: below).isEmpty)
        XCTAssertEqual(layout.pages(intersecting: CGRect(x: 0, y: 0, width: 800, height: 100_000)), 0..<3)
    }

    /// No page that overlaps the rectangle may be left out, and none that does not may be included.
    func testPagesIntersectingMatchesAPlainSearch() {
        var random = Random(state: 23)
        for _ in 0..<300 {
            let sizes = (0..<Int(random.between(1, 40))).map { _ in CGSize(width: random.between(100, 900), height: random.between(50, 1300)) }
            let layout = PageLayout(pageSizes: sizes, scale: random.between(0.25, 8), viewportWidth: random.between(200, 2500))
            for _ in 0..<40 {
                let top = random.between(-200, Double(layout.contentSize.height) + 200)
                let rect = CGRect(x: 0, y: top, width: 100, height: random.between(0.01, 3000))
                let expected = layout.frames.indices.filter { layout.frames[$0].minY < rect.maxY && layout.frames[$0].maxY > rect.minY }
                XCTAssertEqual(Array(layout.pages(intersecting: rect)), expected)
            }
        }
    }

    // MARK: Anchors

    /// The point of an anchor: the same spot on the same page, whatever the scale or window width.
    func testAnchorSurvivesAChangeOfScaleInBothDirections() {
        let before = PageLayout(pageSizes: [a4, a4, a4], scale: 1, viewportWidth: 800)
        let spot = CGPoint(x: before.frames[1].minX + 0.2 * before.frames[1].width, y: before.frames[1].minY + 0.25 * before.frames[1].height)
        let anchor = before.anchor(at: spot)
        XCTAssertEqual(anchor?.page, 1)
        XCTAssertEqual(anchor?.x ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(anchor?.y ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(anchor?.overshoot, 0)
        let after = PageLayout(pageSizes: [a4, a4, a4], scale: 2.5, viewportWidth: 1400)
        let moved = after.point(for: anchor!)
        XCTAssertEqual(moved.x, after.frames[1].minX + 0.2 * after.frames[1].width, accuracy: 0.01)
        XCTAssertEqual(moved.y, after.frames[1].minY + 0.25 * after.frames[1].height, accuracy: 0.01)
    }

    /// A position in the gap below a page keeps its distance from the page in points, because the
    /// gap does not grow with the scale. Stored as a fraction of the page it would drift at each zoom step.
    func testAnchorInAGapDoesNotDriftWhenTheScaleChanges() {
        let before = PageLayout(pageSizes: [a4, a4], scale: 1, viewportWidth: 800)
        let anchor = before.anchor(at: CGPoint(x: 400, y: before.frames[0].maxY + 7))
        XCTAssertEqual(anchor, PageLayout.Anchor(page: 0, x: anchor!.x, y: 1, overshoot: 7))
        for scale in [0.25, 1.25, 3.3, 8] {
            let after = PageLayout(pageSizes: [a4, a4], scale: scale, viewportWidth: 800)
            XCTAssertEqual(after.point(for: anchor!).y, after.frames[0].maxY + 7, accuracy: 0.0001)
        }
    }

    func testAnchorAboveTheFirstPage() {
        let layout = PageLayout(pageSizes: [a4], scale: 1, viewportWidth: 800)
        let anchor = layout.anchor(at: CGPoint(x: 400, y: 0))
        XCTAssertEqual(anchor?.page, 0)
        XCTAssertEqual(anchor?.y, 0)
        XCTAssertEqual(anchor?.overshoot ?? 0, -layout.frames[0].minY, accuracy: 0.0001)
        XCTAssertEqual(layout.point(for: anchor!).y, 0, accuracy: 0.0001)
    }

    func testAnchorRoundTripsEverywhere() {
        var random = Random(state: 31)
        for _ in 0..<200 {
            let sizes = (0..<Int(random.between(1, 20))).map { _ in CGSize(width: random.between(100, 900), height: random.between(50, 1300)) }
            let layout = PageLayout(pageSizes: sizes, scale: random.between(0.25, 8), viewportWidth: random.between(200, 2500))
            for _ in 0..<30 {
                let point = CGPoint(x: random.between(0, Double(layout.contentSize.width)), y: random.between(-50, Double(layout.contentSize.height) + 50))
                let back = layout.point(for: layout.anchor(at: point)!)
                XCTAssertEqual(back.x, point.x, accuracy: 0.001)
                XCTAssertEqual(back.y, point.y, accuracy: 0.001)
            }
        }
    }

    func testAnchorForMissingPageFallsBackToNearest() {
        let layout = PageLayout(pageSizes: [letter], scale: 1, viewportWidth: 800)
        XCTAssertEqual(layout.point(for: PageLayout.Anchor(page: 9)).y, layout.frames[0].minY)
        XCTAssertEqual(layout.point(for: PageLayout.Anchor(page: -3)).y, layout.frames[0].minY)
    }

    func testZoomIsClamped() {
        XCTAssertEqual(Zoom.clamped(0.01), Zoom.minimum)
        XCTAssertEqual(Zoom.clamped(99), Zoom.maximum)
        XCTAssertEqual(Zoom.clamped(.nan), 1)
        XCTAssertEqual(Zoom.clamped(1.5), 1.5)
    }
}
