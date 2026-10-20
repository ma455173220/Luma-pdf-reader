import PDFKit
import XCTest
@testable import LumaCore

final class PageLinksTests: XCTestCase {
    private func document() throws -> PDFDocument { try XCTUnwrap(PDFDocument(data: Data(LinkPDF.bytes()))) }

    private func linksOnPageOne() throws -> [PageLink] {
        let document = try document()
        return PageLinks.links(on: try XCTUnwrap(document.page(at: 0)), in: document)
    }

    private func link(in links: [PageLink], at rect: CGRect) -> PageLink? {
        links.first { abs($0.rect.minX - rect.minX) < 1 && abs($0.rect.minY - rect.minY) < 1 && abs($0.rect.width - rect.width) < 1 }
    }

    func testLinkToASpotCarriesThePageAndThePoint() throws {
        let found = try XCTUnwrap(link(in: try linksOnPageOne(), at: LinkPDF.toSpotOnPageThree))
        XCTAssertEqual(found.target, .place(page: 2, point: CGPoint(x: 100, y: 500)))
    }

    func testLinkThatOnlyNamesAPageHasNoPoint() throws {
        let found = try XCTUnwrap(link(in: try linksOnPageOne(), at: LinkPDF.toPageTwo))
        XCTAssertEqual(found.target, .place(page: 1, point: nil))
    }

    /// A link may name a height without a horizontal position. The system engine does not pass that
    /// height on, so such a link can only be treated as naming the page. Recorded here so that a
    /// change in the engine's behaviour is noticed.
    func testLinkThatOnlyNamesAHeightIsTreatedAsNamingThePage() throws {
        let found = try XCTUnwrap(link(in: try linksOnPageOne(), at: LinkPDF.toHeightOnPageThree))
        XCTAssertEqual(found.target, .place(page: 2, point: nil))
    }

    func testWebLinkCarriesItsAddress() throws {
        let found = try XCTUnwrap(link(in: try linksOnPageOne(), at: LinkPDF.toWeb))
        XCTAssertEqual(found.target, .web(URL(string: "https://doi.org/10.1000/example")!))
    }

    func testLinkToALocalFileIsIgnored() throws {
        let links = try linksOnPageOne()
        XCTAssertNil(link(in: links, at: LinkPDF.toLocalFile))
        XCTAssertEqual(links.count, 5)
    }

    func testOnlyWebAndMailAddressesAreSafeToOpen() {
        XCTAssertTrue(PageLinks.isSafeToOpen(URL(string: "https://doi.org/x")!))
        XCTAssertTrue(PageLinks.isSafeToOpen(URL(string: "HTTP://example.org")!))
        XCTAssertTrue(PageLinks.isSafeToOpen(URL(string: "mailto:someone@example.org")!))
        XCTAssertFalse(PageLinks.isSafeToOpen(URL(string: "file:///etc/hosts")!))
        XCTAssertFalse(PageLinks.isSafeToOpen(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(PageLinks.isSafeToOpen(URL(string: "x-apple-something://run")!))
    }

    func testPagesWithoutLinksHaveNone() throws {
        let document = try document()
        XCTAssertTrue(PageLinks.links(on: try XCTUnwrap(document.page(at: 1)), in: document).isEmpty)
    }

    func testFindingTheLinkUnderAPoint() throws {
        let links = try linksOnPageOne()
        XCTAssertEqual(PageLinks.link(at: CGPoint(x: 80, y: 660), in: links)?.target, .place(page: 1, point: nil))
        XCTAssertNil(PageLinks.link(at: CGPoint(x: 300, y: 300), in: links))
        XCTAssertNil(PageLinks.link(at: CGPoint(x: 80, y: 580), in: links), "the ignored link must not be clickable")
        XCTAssertNil(PageLinks.link(at: .zero, in: []))
    }

    func testWhereLinksOverlapTheOneOnTopWins() throws {
        let links = try linksOnPageOne()
        XCTAssertEqual(PageLinks.link(at: CGPoint(x: 125, y: 705), in: links)?.target, .web(URL(string: "https://example.org/on-top")!))
        XCTAssertEqual(PageLinks.link(at: CGPoint(x: 80, y: 705), in: links)?.target, .place(page: 2, point: CGPoint(x: 100, y: 500)),
                       "beside the small link, the large one underneath is still reachable")
    }
}
