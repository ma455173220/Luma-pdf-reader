import PDFKit
import XCTest
@testable import LumaCore

final class DocumentOutlineTests: XCTestCase {
    private func entries() throws -> [OutlineEntry] {
        DocumentOutline.entries(of: try XCTUnwrap(PDFDocument(data: Data(OutlinePDF.bytes()))))
    }

    func testEntriesComeInReadingOrderWithTheirDepth() throws {
        let entries = try entries()
        XCTAssertEqual(entries.map(\.title), ["1. Introduction", "2. Results", "2.1 First", "2.2 Second", "2.2.1 Deep", "References 参考文献"])
        XCTAssertEqual(entries.map(\.depth), [0, 0, 1, 1, 2, 0])
        XCTAssertEqual(entries.map(\.hasChildren), [false, true, false, true, false, false])
    }

    func testEntriesCarryThePageAndSpotTheyLeadTo() throws {
        let entries = try entries()
        XCTAssertEqual(entries.map(\.page), [0, 1, 1, 2, 2, 2])
        XCTAssertEqual(entries[0].point, CGPoint(x: 72, y: 700))
        XCTAssertNil(entries[1].point, "an entry that only names a page has no spot")
        XCTAssertEqual(entries[2].point, CGPoint(x: 72, y: 400), "a destination written as an action is read the same way")
        XCTAssertEqual(entries[5].point, CGPoint(x: 72, y: 100))
    }

    func testDocumentWithoutAnOutlineHasNoEntries() throws {
        let document = try XCTUnwrap(PDFDocument(data: Data(OutlinePDF.bytes(withOutline: false))))
        XCTAssertTrue(DocumentOutline.entries(of: document).isEmpty)
    }

    func testEntryCountAndDepthAreCapped() throws {
        let document = try XCTUnwrap(PDFDocument(data: Data(OutlinePDF.bytes())))
        XCTAssertEqual(DocumentOutline.entries(of: document, limit: 3).count, 3)
        XCTAssertEqual(DocumentOutline.entries(of: document, maximumDepth: 1).map(\.depth), [0, 0, 0])
    }

    func testFoldingAnEntryHidesEverythingInsideIt() throws {
        let entries = try entries()
        XCTAssertEqual(DocumentOutline.visibleRows(entries, collapsed: []), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(DocumentOutline.visibleRows(entries, collapsed: [3]), [0, 1, 2, 3, 5], "only 2.2's own child goes")
        XCTAssertEqual(DocumentOutline.visibleRows(entries, collapsed: [1]), [0, 1, 5], "children and grandchildren go")
        XCTAssertEqual(DocumentOutline.visibleRows(entries, collapsed: [1, 3]), [0, 1, 5])
    }

    func testFoldingAnEntryWithoutChildrenChangesNothing() throws {
        let entries = try entries()
        XCTAssertEqual(DocumentOutline.visibleRows(entries, collapsed: [0, 2, 5]), [0, 1, 2, 3, 4, 5])
    }

    func testOutlineStartsWithItsTopTwoLevelsOpen() throws {
        let entries = try entries()
        let collapsed = DocumentOutline.initiallyCollapsed(entries)
        XCTAssertEqual(collapsed, [3])
        XCTAssertEqual(DocumentOutline.visibleRows(entries, collapsed: collapsed), [0, 1, 2, 3, 5])
    }

    func testFindingTheSectionAPageIsIn() throws {
        let entries = try entries()
        XCTAssertEqual(DocumentOutline.entry(containingPage: 0, in: entries), 0)
        XCTAssertEqual(DocumentOutline.entry(containingPage: 1, in: entries), 2, "the last entry starting on that page")
        XCTAssertEqual(DocumentOutline.entry(containingPage: 2, in: entries), 5)
        XCTAssertNil(DocumentOutline.entry(containingPage: 0, in: []))
    }

    func testTheSectionBeingReadIsTheLastHeadingAboveTheLineRead() {
        // 5.1 near the foot of page 0, 5.2 high on page 1, 5.3 lower on page 1.
        let entries = [OutlineEntry(title: "5.", depth: 0, page: 0, point: CGPoint(x: 50, y: 700), hasChildren: true),
                       OutlineEntry(title: "5.1", depth: 1, page: 0, point: CGPoint(x: 50, y: 150), hasChildren: false),
                       OutlineEntry(title: "5.2", depth: 1, page: 1, point: CGPoint(x: 50, y: 600), hasChildren: false),
                       OutlineEntry(title: "5.3", depth: 1, page: 1, point: CGPoint(x: 50, y: 300), hasChildren: false)]
        XCTAssertEqual(DocumentOutline.entry(containing: 0, at: 140, in: entries), 1, "just past 5.1, whatever page is in the middle of the view")
        XCTAssertEqual(DocumentOutline.entry(containing: 0, at: 400, in: entries), 0)
        XCTAssertEqual(DocumentOutline.entry(containing: 1, at: 700, in: entries), 1, "the top of the next page, above 5.2")
        XCTAssertEqual(DocumentOutline.entry(containing: 1, at: 450, in: entries), 2)
        XCTAssertEqual(DocumentOutline.entry(containing: 1, at: nil, in: entries), 3, "without a height, every heading on the page")
    }

    func testOnAPageInTwoColumnsTheHeadingJustAboveTheLineIsTheOneBeingRead() {
        // 3.1.1 low in the left column, 3.1.2 high in the right one.
        let entries = [OutlineEntry(title: "3.1", depth: 1, page: 5, point: CGPoint(x: 48, y: 262), hasChildren: true),
                       OutlineEntry(title: "3.1.1", depth: 2, page: 5, point: CGPoint(x: 48, y: 240), hasChildren: false),
                       OutlineEntry(title: "3.1.2", depth: 2, page: 5, point: CGPoint(x: 303, y: 460), hasChildren: false)]
        XCTAssertEqual(DocumentOutline.entry(containing: 5, at: 216, in: entries), 1)
        XCTAssertEqual(DocumentOutline.entry(containing: 5, at: 450, in: entries), 2, "reading the top of the page")
        XCTAssertEqual(DocumentOutline.entry(containing: 6, at: 700, in: entries), 2, "the next page goes on from the right column")
    }
}
