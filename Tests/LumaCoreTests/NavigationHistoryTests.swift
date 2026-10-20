import XCTest
@testable import LumaCore

final class NavigationHistoryTests: XCTestCase {
    func testNothingToGoBackToAtFirst() {
        var history = NavigationHistory<Int>()
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack(from: 1))
        XCTAssertNil(history.goForward(from: 1))
    }

    func testBackReturnsToWhereTheJumpStartedAndForwardUndoesIt() {
        var history = NavigationHistory<Int>()
        history.jumped(from: 3)                      // on page 3, follows a link to page 20
        XCTAssertEqual(history.goBack(from: 20), 3)
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward(from: 3), 20)
        XCTAssertEqual(history.goBack(from: 20), 3)
    }

    func testSeveralJumpsCanBeRetracedOneByOne() {
        var history = NavigationHistory<Int>()
        history.jumped(from: 1)
        history.jumped(from: 5)
        history.jumped(from: 9)
        XCTAssertEqual(history.goBack(from: 12), 9)
        XCTAssertEqual(history.goBack(from: 9), 5)
        XCTAssertEqual(history.goBack(from: 5), 1)
        XCTAssertNil(history.goBack(from: 1))
        XCTAssertEqual(history.goForward(from: 1), 5)
    }

    func testANewJumpDiscardsTheForwardTrail() {
        var history = NavigationHistory<Int>()
        history.jumped(from: 1)
        _ = history.goBack(from: 8)
        XCTAssertTrue(history.canGoForward)
        history.jumped(from: 1)
        XCTAssertFalse(history.canGoForward)
    }

    func testJumpingTwiceFromTheSamePlaceIsRememberedOnce() {
        var history = NavigationHistory<Int>()
        history.jumped(from: 4)
        history.jumped(from: 4)
        XCTAssertEqual(history.goBack(from: 9), 4)
        XCTAssertNil(history.goBack(from: 4))
    }

    func testTheTrailDoesNotGrowWithoutLimit() {
        var history = NavigationHistory<Int>()
        for place in 0..<500 { history.jumped(from: place) }
        var steps = 0
        var current = 500
        while let place = history.goBack(from: current) {
            current = place
            steps += 1
        }
        XCTAssertEqual(steps, NavigationHistory<Int>.limit)
        XCTAssertEqual(current, 400, "the oldest places are the ones forgotten")
    }
}
