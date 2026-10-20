import XCTest
@testable import LumaCore

final class PageJumpTests: XCTestCase {
    func testPagesCountFromOne() {
        XCTAssertEqual(PageJump.pageIndex(from: "1", pageCount: 12), 0)
        XCTAssertEqual(PageJump.pageIndex(from: " 7 ", pageCount: 12), 6)
        XCTAssertEqual(PageJump.pageIndex(from: "12", pageCount: 12), 11)
    }

    func testNumbersPastEitherEndGoToThatEnd() {
        XCTAssertEqual(PageJump.pageIndex(from: "0", pageCount: 12), 0)
        XCTAssertEqual(PageJump.pageIndex(from: "40", pageCount: 12), 11)
        XCTAssertEqual(PageJump.pageIndex(from: "99999999999999999999999", pageCount: 12), 11)
    }

    func testFullWidthDigitsCount() {
        XCTAssertEqual(PageJump.pageIndex(from: "１２", pageCount: 30), 11)
    }

    func testAnythingElseIsNotAPage() {
        XCTAssertNil(PageJump.pageIndex(from: "", pageCount: 12))
        XCTAssertNil(PageJump.pageIndex(from: "iv", pageCount: 12))
        XCTAssertNil(PageJump.pageIndex(from: "-3", pageCount: 12))
        XCTAssertNil(PageJump.pageIndex(from: "3.5", pageCount: 12))
        XCTAssertNil(PageJump.pageIndex(from: "5", pageCount: 0))
    }
}
