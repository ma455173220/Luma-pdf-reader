import XCTest
@testable import LumaCore

final class HoverPreviewTests: XCTestCase {
    private typealias State = HoverPreviewState<String>

    func testPreviewAppearsOnlyAfterThePointerHasRested() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        XCTAssertEqual(state.deadline, 0.4)
        XCTAssertEqual(state.timeReached(0.3), .none, "too early")
        XCTAssertEqual(state.timeReached(0.4), .show("a"))
        XCTAssertEqual(state.shown, "a")
        XCTAssertNil(state.deadline)
    }

    func testPassingOverALinkShowsNothing() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        state.pointer(over: nil, insidePreview: false, at: 0.2)
        XCTAssertNil(state.deadline)
        XCTAssertEqual(state.timeReached(1), .none)
    }

    func testMovingToAnotherLinkStartsTheWaitAgain() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        state.pointer(over: "b", insidePreview: false, at: 0.3)
        XCTAssertEqual(state.timeReached(0.45), .none, "0.4 s after the first link, but only 0.15 s on the second")
        XCTAssertEqual(state.timeReached(0.7), .show("b"))
    }

    func testMovingAroundOnTheSameLinkDoesNotRestartTheWait() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        state.pointer(over: "a", insidePreview: false, at: 0.35)
        XCTAssertEqual(state.timeReached(0.4), .show("a"))
    }

    func testPreviewGoesAwayShortlyAfterThePointerLeaves() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        _ = state.timeReached(0.4)
        state.pointer(over: nil, insidePreview: false, at: 1)
        XCTAssertEqual(state.deadline, 1.25)
        XCTAssertEqual(state.timeReached(1.1), .none)
        XCTAssertEqual(state.timeReached(1.25), .hide)
        XCTAssertNil(state.shown)
    }

    /// The reason for the short wait on leaving: the pointer must be able to cross into the preview.
    func testPointerCanTravelFromTheLinkIntoThePreview() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        _ = state.timeReached(0.4)
        state.pointer(over: nil, insidePreview: false, at: 1)
        state.pointer(over: nil, insidePreview: true, at: 1.1)
        XCTAssertNil(state.deadline, "inside the preview nothing is counting down")
        XCTAssertEqual(state.timeReached(5), .none)
        XCTAssertEqual(state.shown, "a")
        state.pointer(over: nil, insidePreview: false, at: 6)
        XCTAssertEqual(state.timeReached(6.25), .hide)
    }

    func testComingBackToTheLinkCancelsTheCountdown() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        _ = state.timeReached(0.4)
        state.pointer(over: nil, insidePreview: false, at: 1)
        state.pointer(over: "a", insidePreview: false, at: 1.1)
        XCTAssertEqual(state.timeReached(2), .none)
        XCTAssertEqual(state.shown, "a")
    }

    func testLeavingTimeIsCountedFromWhenThePointerFirstLeft() {
        var state = State()
        state.pointer(over: "a", insidePreview: false, at: 0)
        _ = state.timeReached(0.4)
        state.pointer(over: nil, insidePreview: false, at: 1)
        state.pointer(over: "b", insidePreview: false, at: 1.2)
        XCTAssertEqual(state.deadline, 1.25, "wandering onto another link does not keep the first preview open")
    }

    func testDismissHidesAtOnceAndForgetsAWait() {
        var showing = State()
        showing.pointer(over: "a", insidePreview: false, at: 0)
        _ = showing.timeReached(0.4)
        XCTAssertEqual(showing.dismiss(), .hide)
        XCTAssertNil(showing.shown)

        var waiting = State()
        waiting.pointer(over: "a", insidePreview: false, at: 0)
        XCTAssertEqual(waiting.dismiss(), .none)
        XCTAssertEqual(waiting.timeReached(1), .none)
    }

    // MARK: Sizes and places

    func testPreviewShowsTheWholeWidthOfThePage() {
        let plan = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 595, height: 842), destinationFromTop: nil, previewSize: CGSize(width: 640, height: 380))
        XCTAssertEqual(plan.pageSize.width, 640, accuracy: 0.001)
        XCTAssertEqual(plan.scale, 640.0 / 595.0, accuracy: 0.0001)
        XCTAssertEqual(plan.scrollY, 0, "a link that only names a page shows its top")
    }

    func testPreviewStartsJustAboveTheSpotTheLinkLeadsTo() {
        let plan = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 600, height: 800), destinationFromTop: 300, previewSize: CGSize(width: 600, height: 380))
        XCTAssertEqual(plan.scrollY, 300 - 8)
    }

    func testPreviewNeverScrollsPastTheEndsOfThePage() {
        let nearTheEnd = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 600, height: 800), destinationFromTop: 790, previewSize: CGSize(width: 600, height: 380))
        XCTAssertEqual(nearTheEnd.scrollY, 800 - 380)
        let atTheTop = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 600, height: 800), destinationFromTop: 3, previewSize: CGSize(width: 600, height: 380))
        XCTAssertEqual(atTheTop.scrollY, 0)
        let shortPage = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 600, height: 200), destinationFromTop: 150, previewSize: CGSize(width: 600, height: 380))
        XCTAssertEqual(shortPage.scrollY, 0, "a page shorter than the preview has nowhere to scroll")
    }

    func testPreviewPlanSurvivesNonsenseSizes() {
        XCTAssertEqual(PreviewGeometry.plan(pageDisplaySize: .zero, destinationFromTop: 5, previewSize: CGSize(width: 600, height: 380)).pageSize, .zero)
        XCTAssertEqual(PreviewGeometry.plan(pageDisplaySize: CGSize(width: 600, height: 800), destinationFromTop: 5, previewSize: .zero).pageSize, .zero)
    }

    func testPreviewIsSmallerInASmallWindow() {
        XCTAssertEqual(PreviewGeometry.previewSize(in: CGSize(width: 2000, height: 1200)), CGSize(width: 640, height: 380))
        XCTAssertEqual(PreviewGeometry.previewSize(in: CGSize(width: 420, height: 320)), CGSize(width: 404, height: 160))
    }

    private let container = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 640, height: 380)

    func testPreviewSitsUnderTheLinkWhenThereIsRoom() {
        let link = CGRect(x: 480, y: 100, width: 40, height: 14)
        let frame = PreviewGeometry.frame(forPreviewOfSize: size, near: link, in: container)
        XCTAssertEqual(frame.minY, link.maxY + 6)
        XCTAssertEqual(frame.midX, link.midX, accuracy: 0.001)
    }

    func testPreviewGoesAboveALinkNearTheBottom() {
        let link = CGRect(x: 480, y: 700, width: 40, height: 14)
        let frame = PreviewGeometry.frame(forPreviewOfSize: size, near: link, in: container)
        XCTAssertEqual(frame.maxY, link.minY - 6)
        XCTAssertFalse(frame.intersects(link), "the preview must not cover the link it belongs to")
    }

    func testPreviewStaysInsideTheWindowNearTheEdges() {
        for link in [CGRect(x: 4, y: 100, width: 30, height: 14), CGRect(x: 970, y: 100, width: 30, height: 14)] {
            let frame = PreviewGeometry.frame(forPreviewOfSize: size, near: link, in: container)
            XCTAssertGreaterThanOrEqual(frame.minX, 8)
            XCTAssertLessThanOrEqual(frame.maxX, 992)
        }
    }

    func testPreviewInAWindowTooSmallForItStillLandsInside() {
        let small = CGRect(x: 0, y: 0, width: 420, height: 320)
        let frame = PreviewGeometry.frame(forPreviewOfSize: CGSize(width: 404, height: 160), near: CGRect(x: 200, y: 150, width: 30, height: 14), in: small)
        XCTAssertTrue(small.contains(frame))
    }

    // MARK: Two-column pages

    private func twoColumns(lines: Int = 20) -> [CGRect] {
        (0..<lines).flatMap { k -> [CGRect] in
            let y = 700 - CGFloat(k) * 12
            return [CGRect(x: 50, y: y, width: 240, height: 10), CGRect(x: 320, y: y, width: 240, height: 10)]
        }
    }

    func testATwoColumnPageGivesTheColumnOfThePoint() {
        let lines = twoColumns() + [CGRect(x: 50, y: 760, width: 510, height: 14)]   // a title across both
        XCTAssertEqual(PageColumns.column(containing: 100, lines: lines, width: 612), 50...290)
        XCTAssertEqual(PageColumns.column(containing: 400, lines: lines, width: 612), 320...560)
    }

    func testASingleColumnPageGivesNone() {
        let lines = (0..<30).map { CGRect(x: 72, y: 700 - CGFloat($0) * 12, width: 468, height: 10) }
        XCTAssertNil(PageColumns.column(containing: 100, lines: lines, width: 612))
        XCTAssertNil(PageColumns.column(containing: 100, lines: Array(twoColumns(lines: 3)), width: 612), "too few lines to tell")
        // Mostly lines across the middle, a few short ones: not two columns.
        let mixed = (0..<20).map { CGRect(x: 72, y: 700 - CGFloat($0) * 12, width: 468, height: 10) } + twoColumns(lines: 6)
        XCTAssertNil(PageColumns.column(containing: 100, lines: mixed, width: 612))
    }

    func testAColumnIsShownAsWideAsThePreview() {
        let plan = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 612, height: 792), destinationFromTop: 200,
                                        previewSize: CGSize(width: 640, height: 380), column: 320...560)
        XCTAssertEqual(plan.scale, (640 - 12) / 240, accuracy: 0.001, "about twice the size of the whole page's width")
        XCTAssertEqual(plan.scrollX, 320 * plan.scale - 6, accuracy: 0.5)
        XCTAssertEqual(plan.scrollY, 200 * plan.scale - 8, accuracy: 0.5)
    }
}
