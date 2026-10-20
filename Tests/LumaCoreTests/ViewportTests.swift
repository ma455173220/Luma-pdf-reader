import XCTest
@testable import LumaCore

final class ViewportTests: XCTestCase {
    private let a4 = CGSize(width: 595.276, height: 841.89)
    private let viewport = CGSize(width: 800, height: 600)

    private func layout(scale: CGFloat) -> PageLayout {
        PageLayout(pageSizes: [a4, a4, a4], scale: scale, viewportWidth: viewport.width)
    }

    func testWithNoAnchorItStartsAtTheTopAndCentred() {
        let wide = layout(scale: 3)
        let origin = Viewport.origin(placing: nil, at: .zero, in: wide, viewportSize: viewport)
        XCTAssertEqual(origin.y, 0)
        XCTAssertEqual(origin.x, (wide.contentSize.width - viewport.width) / 2, accuracy: 0.001)
        XCTAssertEqual(Viewport.origin(placing: nil, at: .zero, in: layout(scale: 0.5), viewportSize: viewport), .zero)
    }

    func testAnchorLandsAtTheRequestedSpotOfTheViewport() {
        let wide = layout(scale: 3)
        let anchor = PageLayout.Anchor(page: 1, x: 0.3, y: 0.4)
        let offset = CGPoint(x: 250, y: 120)
        let origin = Viewport.origin(placing: anchor, at: offset, in: wide, viewportSize: viewport)
        let spot = wide.point(for: anchor)
        XCTAssertEqual(origin.x + offset.x, spot.x, accuracy: 0.001)
        XCTAssertEqual(origin.y + offset.y, spot.y, accuracy: 0.001)
    }

    /// Zooming in while looking left of centre must not jump back to the middle of the page.
    func testZoomingKeepsTheHorizontalPosition() {
        let before = layout(scale: 2)
        let offset = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        // The middle of the viewport shows a spot two fifths of the way across page 2: left of centre,
        // and far enough in that the view is not pressed against the left edge of the content.
        let anchor = PageLayout.Anchor(page: 1, x: 0.4, y: 0.5)
        let start = Viewport.origin(placing: anchor, at: offset, in: before, viewportSize: viewport)
        XCTAssertGreaterThan(start.x, 0, "the scenario must not be one where the view is pinned to the edge")
        XCTAssertEqual(before.anchor(at: CGPoint(x: start.x + offset.x, y: start.y + offset.y))?.x ?? 0, 0.4, accuracy: 0.001)

        let after = layout(scale: 2 * Zoom.step)
        let end = Viewport.origin(placing: anchor, at: offset, in: after, viewportSize: viewport)
        let seen = after.anchor(at: CGPoint(x: end.x + offset.x, y: end.y + offset.y))
        XCTAssertEqual(seen?.x ?? 0, 0.4, accuracy: 0.001, "still two fifths of the way across, not the middle")
        XCTAssertEqual(seen?.y ?? 0, 0.5, accuracy: 0.001)
        // And it really is somewhere other than centred, or the test would prove nothing.
        XCTAssertNotEqual(end.x, (after.contentSize.width - viewport.width) / 2, accuracy: 1)
    }

    func testOriginNeverLeavesTheContent() {
        let wide = layout(scale: 3)
        let furthest = CGPoint(x: wide.contentSize.width - viewport.width, y: wide.contentSize.height - viewport.height)
        let pastTheEnd = Viewport.origin(placing: PageLayout.Anchor(page: 2, x: 1, y: 1, overshoot: 500), at: .zero, in: wide, viewportSize: viewport)
        XCTAssertEqual(pastTheEnd.x, furthest.x, accuracy: 0.001)
        XCTAssertEqual(pastTheEnd.y, furthest.y, accuracy: 0.001)
        let beforeTheStart = Viewport.origin(placing: PageLayout.Anchor(page: 0, x: -5, y: 0, overshoot: -500), at: CGPoint(x: 900, y: 900), in: wide, viewportSize: viewport)
        XCTAssertEqual(beforeTheStart, .zero)
    }

    func testContentSmallerThanViewportNeverScrolls() {
        let small = PageLayout(pageSizes: [CGSize(width: 200, height: 100)], scale: 1, viewportWidth: viewport.width)
        let origin = Viewport.origin(placing: PageLayout.Anchor(page: 0, x: 0.9, y: 0.9), at: .zero, in: small, viewportSize: viewport)
        XCTAssertEqual(origin, .zero)
    }

    func testEmptyDocumentAndZeroViewport() {
        let empty = PageLayout(pageSizes: [], scale: 1, viewportWidth: 0)
        XCTAssertEqual(Viewport.origin(placing: PageLayout.Anchor(page: 0), at: .zero, in: empty, viewportSize: .zero), .zero)
    }

    // MARK: Tabs

    func testClosingATabBeforeTheSelectedOneKeepsTheSameDocumentSelected() {
        XCTAssertEqual(TabList.selection(afterClosing: 0, selected: 2, count: 4), 1)
    }

    func testClosingATabAfterTheSelectedOneChangesNothing() {
        XCTAssertEqual(TabList.selection(afterClosing: 3, selected: 1, count: 4), 1)
    }

    func testClosingTheSelectedTabMovesToTheOneThatTakesItsPlace() {
        XCTAssertEqual(TabList.selection(afterClosing: 1, selected: 1, count: 4), 1)
    }

    func testClosingTheSelectedLastTabMovesToTheNewLastOne() {
        XCTAssertEqual(TabList.selection(afterClosing: 3, selected: 3, count: 4), 2)
    }

    func testClosingTheOnlyTabLeavesNothingSelected() {
        XCTAssertNil(TabList.selection(afterClosing: 0, selected: 0, count: 1))
        XCTAssertNil(TabList.selection(afterClosing: 0, selected: 0, count: 0))
    }

    func testEveryCombinationKeepsTheSelectionInsideTheList() {
        for count in 2...6 {
            for selected in 0..<count {
                for closed in 0..<count {
                    let result = TabList.selection(afterClosing: closed, selected: selected, count: count)
                    XCTAssertNotNil(result)
                    XCTAssertTrue((0..<(count - 1)).contains(result ?? -1), "closed \(closed), selected \(selected), count \(count)")
                    // Unless the selected tab itself was closed, the same document must stay selected.
                    if closed != selected { XCTAssertEqual(result, closed < selected ? selected - 1 : selected) }
                }
            }
        }
    }

    func testOutOfRangeInputsAreTolerated() {
        XCTAssertEqual(TabList.selection(afterClosing: 9, selected: 1, count: 3), 1)
        XCTAssertEqual(TabList.selection(afterClosing: -1, selected: 5, count: 3), 1)
    }
}
