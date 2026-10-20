import XCTest
@testable import LumaCore

final class TabStripLayoutTests: XCTestCase {
    private func strip(_ count: Int, width: CGFloat, scroll: CGFloat = 0) -> TabStripLayout {
        TabStripLayout(count: count, width: width, height: 30, scrollOffset: scroll)
    }

    func testFewTabsDoNotStretchBeyondTheirMaximum() {
        let layout = strip(2, width: 1200)
        XCTAssertEqual(layout.tabWidth, TabStripLayout.maximumTabWidth)
        XCTAssertEqual(layout.maximumScrollOffset, 0)
    }

    func testTabsShareTheStripWhileTheyFit() {
        let layout = strip(8, width: 1200)
        XCTAssertEqual(layout.tabWidth, 150)
        XCTAssertEqual(layout.tabFrame(7).maxX, 1200)
    }

    /// The fault this type exists to prevent: tabs so narrow that most of each is its close box.
    func testTabsNeverShrinkBelowAReadableWidth() {
        for count in [7, 15, 40] {
            let layout = strip(count, width: 420)
            XCTAssertEqual(layout.tabWidth, TabStripLayout.minimumTabWidth)
            let closeBoxShare = TabStripLayout.closeBoxSize / layout.tabWidth
            XCTAssertLessThan(closeBoxShare, 0.2, "\(count) tabs in the narrowest window")
        }
        XCTAssertEqual(strip(15, width: 420).maximumScrollOffset, 15 * TabStripLayout.minimumTabWidth - 420)
    }

    func testScrollOffsetStaysWithinWhatThereIsToScroll() {
        XCTAssertEqual(strip(15, width: 420, scroll: -50).scrollOffset, 0)
        XCTAssertEqual(strip(15, width: 420, scroll: 99_999).scrollOffset, strip(15, width: 420).maximumScrollOffset)
        XCTAssertEqual(strip(2, width: 1200, scroll: 300).scrollOffset, 0, "nothing to scroll when everything fits")
    }

    func testClickSelectsTheTabUnderIt() {
        let layout = strip(4, width: 800)
        XCTAssertEqual(layout.hit(at: CGPoint(x: 10, y: 15), closeBoxShowingOn: []), .select(0))
        XCTAssertEqual(layout.hit(at: CGPoint(x: 799, y: 15), closeBoxShowingOn: []), .select(3))
        XCTAssertEqual(layout.hit(at: CGPoint(x: 200, y: 15), closeBoxShowingOn: []), .select(1), "a tab starts at its own left edge")
    }

    func testClickAccountsForScrolling() {
        let layout = strip(15, width: 420, scroll: 96 * 3)
        XCTAssertEqual(layout.hit(at: CGPoint(x: 5, y: 15), closeBoxShowingOn: []), .select(3))
        XCTAssertEqual(layout.tabFrame(3).minX, 0)
    }

    func testCloseBoxOnlyWorksWhereItIsShowing() {
        let layout = strip(4, width: 800)
        let onCloseBoxOfTabOne = CGPoint(x: layout.closeBox(1).midX, y: layout.closeBox(1).midY)
        XCTAssertEqual(layout.hit(at: onCloseBoxOfTabOne, closeBoxShowingOn: [1]), .close(1))
        XCTAssertEqual(layout.hit(at: onCloseBoxOfTabOne, closeBoxShowingOn: [0, 2]), .select(1), "an invisible close box must not close anything")
    }

    func testCloseBoxDoesNotReachBeyondItsOwnSquare() {
        let layout = strip(4, width: 800)
        let box = layout.closeBox(2)
        XCTAssertEqual(layout.hit(at: CGPoint(x: box.maxX + 1, y: box.midY), closeBoxShowingOn: [2]), .select(2))
        XCTAssertEqual(layout.hit(at: CGPoint(x: box.minX - 1, y: box.midY), closeBoxShowingOn: [2]), .select(2))
        XCTAssertEqual(layout.hit(at: CGPoint(x: box.midX, y: box.minY - 1), closeBoxShowingOn: [2]), .select(2))
    }

    func testClicksOutsideTheTabsDoNothing() {
        let layout = strip(2, width: 1200)
        XCTAssertEqual(layout.hit(at: CGPoint(x: 900, y: 15), closeBoxShowingOn: [0, 1]), .nothing, "empty space to the right of the last tab")
        XCTAssertEqual(layout.hit(at: CGPoint(x: -1, y: 15), closeBoxShowingOn: []), .nothing)
        XCTAssertEqual(layout.hit(at: CGPoint(x: 10, y: 31), closeBoxShowingOn: []), .nothing)
        XCTAssertEqual(strip(0, width: 800).hit(at: CGPoint(x: 10, y: 15), closeBoxShowingOn: []), .nothing)
    }

    func testRevealingATabScrollsJustEnough() {
        let layout = strip(15, width: 420)
        XCTAssertEqual(layout.scrollOffset(revealing: 0), 0)
        let toLast = layout.scrollOffset(revealing: 14)
        XCTAssertEqual(toLast, layout.maximumScrollOffset)
        let scrolled = strip(15, width: 420, scroll: toLast)
        XCTAssertEqual(scrolled.tabFrame(14).maxX, 420, accuracy: 0.001)
        XCTAssertEqual(scrolled.scrollOffset(revealing: 12), toLast, "already visible, so nothing moves")
        XCTAssertEqual(scrolled.scrollOffset(revealing: 2), 2 * TabStripLayout.minimumTabWidth)
        XCTAssertEqual(scrolled.scrollOffset(revealing: 99), toLast, "a tab that does not exist changes nothing")
    }
}
