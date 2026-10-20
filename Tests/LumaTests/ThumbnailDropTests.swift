import LumaCore
import PDFKit
import XCTest
@testable import Luma

/// Where a file dropped on the thumbnails goes.
final class ThumbnailDropTests: XCTestCase {
    func testTheSpaceBelowTheLastThumbnailAppends() throws {
        let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        let document = try XCTUnwrap(PDFDocument(data: data))
        // A column far taller than two thumbnails.
        let view = ThumbnailListView(frame: NSRect(x: 0, y: 0, width: 200, height: 1200))
        view.show(document, pageSizes: [CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)], currentPage: 0)
        XCTAssertGreaterThanOrEqual(view.debugCanvasHeight, 1199, "the thumbnails reach the bottom of the column")
        XCTAssertEqual(view.debugDropGap(atY: 1100), 2, "the empty space below the last thumbnail appends")
    }
}

final class ThumbnailDragTests: XCTestCase {
    func testLettingGoBesideTheColumnMovesNothing() throws {
        var bodies = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"]
        bodies += Array(repeating: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>", count: 3)
        var out = "%PDF-1.7\n"
        for (k, body) in bodies.enumerated() { out += "\(k + 1) 0 obj\n\(body)\nendobj\n" }
        out += "trailer\n<< /Root 1 0 R >>\n%%EOF\n"
        let document = try XCTUnwrap(PDFDocument(data: Data(out.utf8)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        let view = ThumbnailListView(frame: NSRect(x: 0, y: 0, width: 200, height: 900))
        window.contentView?.addSubview(view)
        view.show(document, pageSizes: Array(repeating: CGSize(width: 612, height: 792), count: 3), currentPage: 0)
        var moves: [(Int, Int)] = []
        view.actions = ThumbnailActions(move: { moves.append(($0, $1)) })
        view.debugPickUp(0, overGap: 2)
        XCTAssertTrue(view.debugIsFloating, "the page picked up floats with the pointer")
        view.debugLetGo()
        XCTAssertFalse(view.debugIsFloating, "and is put down when let go")
        XCTAssertEqual(moves.count, 1)
        moves.removeAll()
        view.debugDragOut(0)
        XCTAssertTrue(moves.isEmpty, "let go beside the column")
        view.debugDrag(0, toGap: 3)
        XCTAssertEqual(moves.count, 1, "let go in the column")
    }
}

final class PinnedPreviewTests: XCTestCase {
    func testATurnedPageIsDrawnTheRightWayRound() throws {
        let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let plan = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 612, height: 792), destinationFromTop: nil, previewSize: CGSize(width: 306, height: 200))
        let preview = PreviewPopupView(frame: NSRect(x: 0, y: 0, width: 306, height: 200), page: page, plan: plan)
        XCTAssertEqual(preview.debugDrawnSize.width, 306, accuracy: 0.5)
        XCTAssertEqual(preview.debugDrawnSize.height, 396, accuracy: 0.5)
        page.rotation = 90
        preview.pageChanged()
        XCTAssertEqual(preview.debugDrawnSize.width, 396, accuracy: 0.5, "not squeezed into the old shape")
        XCTAssertEqual(preview.debugDrawnSize.height, 306, accuracy: 0.5)
    }
}

final class PinnedPreviewPlaceTests: XCTestCase {
    func testAPinnedPreviewIsBroughtBackInsideASmallerWindow() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Left near the right edge of a larger window.
        let moved = LinkInteractionController.keptInside(CGRect(x: 1100, y: 700, width: 400, height: 250), window)
        XCTAssertEqual(moved, CGRect(x: 392, y: 342, width: 400, height: 250))
        let inside = CGRect(x: 100, y: 100, width: 400, height: 250)
        XCTAssertEqual(LinkInteractionController.keptInside(inside, window), inside, "one already inside stays put")
    }
}

final class TurnShortcutTests: XCTestCase {
    func testTheTurnShortcutsAreOffWhileTyping() {
        XCTAssertTrue(ReaderWindowController.isTyping(NSTextView()), "the search bar's or page number's field editor")
        XCTAssertFalse(ReaderWindowController.isTyping(NSView()))
        XCTAssertFalse(ReaderWindowController.isTyping(nil))
    }
}

final class PreviewZoomTests: XCTestCase {
    private let shown = CGSize(width: 612, height: 792)

    func testZoomGoesFromTheWholePageToFourTimesItsWidth() {
        let range = PreviewZoom.range(page: shown, view: CGSize(width: 640, height: 380), start: 2.3)
        XCTAssertEqual(range.lowerBound, 380.0 / 792, accuracy: 0.0001, "the whole page just fits")
        XCTAssertEqual(range.upperBound, 4 * 640.0 / 612, accuracy: 0.0001)
        XCTAssertEqual(PreviewZoom.range(page: shown, view: CGSize(width: 640, height: 380), start: 6).upperBound, 6, "the scale it opened at stays reachable")
    }

    func testTheSpotUnderThePointerStaysUnderIt() {
        let range = PreviewZoom.range(page: shown, view: CGSize(width: 640, height: 380), start: 1)
        let zoomed = PreviewZoom.zoomed(scale: 1, offset: CGPoint(x: 0, y: 100), by: 2, around: CGPoint(x: 100, y: 50),
                                        page: shown, view: CGSize(width: 640, height: 380), range: range)
        XCTAssertEqual(zoomed.scale, 2)
        XCTAssertEqual(zoomed.offset, CGPoint(x: 100, y: 250))
        let most = PreviewZoom.zoomed(scale: 1, offset: .zero, by: 100, around: .zero, page: shown, view: CGSize(width: 640, height: 380), range: range)
        XCTAssertEqual(most.scale, range.upperBound, "no further than four times")
    }

    func testScrollBarsShowOnlyWhereThePageIsLargerThanThePreview() throws {
        let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let size = CGSize(width: 306, height: 200)
        let plan = PreviewGeometry.plan(pageDisplaySize: shown, destinationFromTop: nil, previewSize: size)
        let preview = PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: page, plan: plan)
        XCTAssertTrue(preview.debugBars.vertical, "the page is taller than the preview")
        XCTAssertFalse(preview.debugBars.horizontal, "and as wide")
        XCTAssertEqual(preview.debugBars.verticalValue, 0, accuracy: 0.001, "at the top")
        preview.debugZoom(by: 3)
        XCTAssertTrue(preview.debugBars.horizontal, "zoomed in, wider too")
        preview.debugZoom(by: 0.001)
        XCTAssertFalse(preview.debugBars.vertical || preview.debugBars.horizontal, "the whole page fits: none")
    }

    func testShrinkingFromTheBottomKeepsTheTopInView() throws {
        let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let size = CGSize(width: 640, height: 380)
        let plan = PreviewGeometry.plan(pageDisplaySize: shown, destinationFromTop: 300, previewSize: size)
        let preview = PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: page, plan: plan)
        let start = preview.debugOffset
        preview.debugResize(to: CGSize(width: 640, height: 200), by: .bottom)
        XCTAssertEqual(preview.debugOffset, start, "the cited line near the top stays where it was")
        preview.debugResize(to: CGSize(width: 640, height: 150), by: .top)
        XCTAssertEqual(preview.debugOffset.y, start.y + 50, accuracy: 0.5, "dragging the top down: the bottom stays put")
    }

    func testAPageSmallerThanThePreviewIsCentred() {
        let kept = PreviewZoom.kept(CGPoint(x: 50, y: 900), drawn: CGSize(width: 300, height: 388), view: CGSize(width: 640, height: 380))
        XCTAssertEqual(kept, CGPoint(x: -170, y: 8), "centred across, kept on the page down")
    }

    func testATwoColumnPreviewOpensOnTheColumnAndZoomsOutToTheWholePage() throws {
        let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let size = CGSize(width: 640, height: 380)
        let column = PreviewGeometry.plan(pageDisplaySize: shown, destinationFromTop: 100, previewSize: size, column: 320...560)
        let preview = PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: page, plan: column)
        XCTAssertEqual(preview.debugScale, column.scale, accuracy: 0.0001, "the column the link leads into at first")
        preview.debugZoom(by: 0.001)
        XCTAssertEqual(preview.debugDrawnSize.height, 380, accuracy: 0.5, "zoomed out, the whole page")
        preview.debugZoom(by: 1000)
        XCTAssertEqual(preview.debugDrawnSize.width, 4 * 640, accuracy: 0.5, "zoomed in, four times the width")
    }
}

final class PinnedPreviewSizeTests: XCTestCase {
    func testAPinnedPreviewIsMadeLargerOrSmallerWithinItsLimits() {
        let start = CGSize(width: 640, height: 380), room = CGSize(width: 2000, height: 2000)
        XCTAssertEqual(PreviewPopupView.resized(start, by: CGSize(width: 100, height: 50), room: room), CGSize(width: 740, height: 430))
        XCTAssertEqual(PreviewPopupView.resized(start, by: CGSize(width: -900, height: -900), room: room), PreviewPopupView.smallest)
        XCTAssertEqual(PreviewPopupView.resized(start, by: CGSize(width: 5000, height: 5000), room: room), PreviewPopupView.largest)
        XCTAssertEqual(PreviewPopupView.resized(start, by: CGSize(width: 5000, height: 5000), room: CGSize(width: 900, height: 700)),
                       CGSize(width: 900, height: 700), "never past the window")
    }

    func testEveryEdgeAndCornerCanBeTakenHoldOf() {
        let size = CGSize(width: 640, height: 380)
        typealias E = PreviewPopupView.Edges
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 320, y: 190), in: size), [], "the middle moves it")
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 3, y: 190), in: size), E.left)
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 637, y: 190), in: size), E.right)
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 320, y: 2), in: size), E.top)
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 320, y: 377), in: size), E.bottom)
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 12, y: 14), in: size), [E.left, E.top], "a corner is wider than an edge")
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 630, y: 368), in: size), [E.right, E.bottom])
        XCTAssertEqual(PreviewPopupView.edges(at: CGPoint(x: 8, y: 190), in: size), [], "past the edge band, where the scroll bars are")
    }

    func testDraggingAnEdgeKeepsTheOppositeOneWhereItWas() {
        let start = CGRect(x: 200, y: 100, width: 640, height: 380), window = CGRect(x: 0, y: 0, width: 1400, height: 900)
        typealias E = PreviewPopupView.Edges
        XCTAssertEqual(PreviewPopupView.resizedFrame(start, edges: E.left, by: CGSize(width: -50, height: 30), within: window),
                       CGRect(x: 150, y: 100, width: 690, height: 380))
        XCTAssertEqual(PreviewPopupView.resizedFrame(start, edges: [E.right, E.top], by: CGSize(width: 40, height: -60), within: window),
                       CGRect(x: 200, y: 40, width: 680, height: 440))
        XCTAssertEqual(PreviewPopupView.resizedFrame(start, edges: E.top, by: CGSize(width: 0, height: 500), within: window),
                       CGRect(x: 200, y: 320, width: 640, height: 160), "no smaller than the smallest, the bottom staying put")
        XCTAssertEqual(PreviewPopupView.resizedFrame(start, edges: [E.left, E.bottom], by: CGSize(width: -900, height: 900), within: window),
                       CGRect(x: 8, y: 100, width: 832, height: 792), "never past the window")
    }

    func testOnARetinaScreenAPinnedPreviewIsKeptWithinItsArea() {
        let area = PreviewPopupView.largestArea(scale: 2)
        XCTAssertGreaterThan(PreviewPopupView.largestArea(scale: 1), 1400 * 1000, "one pixel to the point: the size limits alone")
        let start = CGRect(x: 100, y: 100, width: 640, height: 500), window = CGRect(x: 0, y: 0, width: 2200, height: 1200)
        typealias E = PreviewPopupView.Edges
        let wide = PreviewPopupView.resizedFrame(start, edges: E.right, by: CGSize(width: 2000, height: 0), within: window, area: area)
        XCTAssertEqual(wide.width * wide.height, area, accuracy: 1)
        XCTAssertEqual(wide.minX, 100, "the left edge stays put")
        let corner = PreviewPopupView.resizedFrame(start, edges: [E.left, E.top], by: CGSize(width: -90, height: -90), within: window, area: area)
        XCTAssertLessThanOrEqual(corner.width * corner.height, area + 1)
        XCTAssertEqual(corner.maxX, start.maxX, accuracy: 0.001)
        XCTAssertEqual(corner.maxY, start.maxY, accuracy: 0.001, "the corner opposite stays put")
    }

    func testAShrunkWindowMakesALargePreviewSmallerToFit() {
        let moved = LinkInteractionController.keptInside(CGRect(x: 300, y: 200, width: 1200, height: 900), CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(moved, CGRect(x: 8, y: 8, width: 784, height: 584))
    }

    func testALargerPreviewShowsMoreOfThePageAtTheSameZoom() throws {
        let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let plan = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 612, height: 792), destinationFromTop: nil, previewSize: CGSize(width: 306, height: 200))
        let preview = PreviewPopupView(frame: NSRect(x: 0, y: 0, width: 306, height: 200), page: page, plan: plan)
        preview.setFrameSize(NSSize(width: 400, height: 260))
        XCTAssertEqual(preview.debugDrawnSize.width, 306, accuracy: 0.5, "the same zoom, more of the page around it")
        preview.debugZoom(by: 0.001)
        preview.setFrameSize(NSSize(width: 612, height: 400))
        XCTAssertEqual(preview.debugDrawnSize.height, 400, accuracy: 0.5, "a page zoomed out to the whole grows with the preview")
    }
}

final class PreviewTextSelectionTests: XCTestCase {
    /// One page with one line of text, 72 points in, its baseline 740 points up.
    private func page() throws -> PDFPage {
        let stream = "BT /F1 10 Tf 72 740 Td (Hello wonderful world of text) Tj ET"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [4 0 R] /Count 1 >>",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 3 0 R >> >> >>",
                       "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"]
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let start = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return try XCTUnwrap(PDFDocument(data: Data(out.utf8))?.page(at: 0))
    }

    func testTextInAPreviewCanBeSelectedAndCopied() throws {
        let page = try page()
        let size = CGSize(width: 306, height: 200)
        let plan = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 612, height: 792), destinationFromTop: nil, previewSize: size)
        let preview = PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: page, plan: plan, textPage: { page })
        // The line is 52 points down the page as shown, drawn at half size.
        let copied = preview.debugSelect(from: CGPoint(x: 37, y: 24), to: CGPoint(x: 150, y: 24))
        XCTAssertTrue(copied?.hasPrefix("Hello") ?? false, copied ?? "nothing copied")
        let without = PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: page, plan: plan)
        XCTAssertNil(without.debugSelect(from: CGPoint(x: 37, y: 24), to: CGPoint(x: 150, y: 24)), "no text to read: nothing selected")
    }

    func testOnlyAPreviewOfAReferenceHasItsTwoButtons() throws {
        let page = try page()
        let size = CGSize(width: 306, height: 200)
        let plan = PreviewGeometry.plan(pageDisplaySize: CGSize(width: 612, height: 792), destinationFromTop: nil, previewSize: size)
        let reference = [PreviewText.Line(text: "[3] A. Smith, Phys. Rev. B 12, 345 (2019).", rect: CGRect(x: 72, y: 700, width: 300, height: 10))]
        let preview = PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: page, plan: plan, reference: reference)
        XCTAssertTrue(preview.debugHasReferenceButtons)
        XCTAssertEqual(preview.referenceText, "A. Smith, Phys. Rev. B 12, 345 (2019).", "copied without its number")
        XCTAssertFalse(PreviewPopupView(frame: NSRect(origin: .zero, size: size), page: page, plan: plan).debugHasReferenceButtons)
        let url = try XCTUnwrap(PreviewPopupView.scholarSearch("A. Smith & B. Jones, Phys. Rev. B 12, 345 (2019)."))
        XCTAssertEqual(url.host, "scholar.google.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "A. Smith & B. Jones, Phys. Rev. B 12, 345 (2019).")
        let plus = try XCTUnwrap(PreviewPopupView.scholarSearch("Li+ transport in C60+ films"))
        XCTAssertEqual(URLComponents(url: plus, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Li+ transport in C60+ films", "a plus kept, not read as a space")
    }
}

final class MarkupPanelWidthTests: XCTestCase {
    func testEveryButtonOfTheMarkingPanelFitsInIt() {
        for mode in [MarkupPopoverView.Mode.create(colour: .yellow), .edit(colour: .yellow, note: "")] {
            let panel = MarkupPopoverView(mode: mode)
            panel.layoutSubtreeIfNeeded()
            let row = panel.subviews.compactMap { $0 as? NSStackView }.first
            XCTAssertNotNil(row)
            XCTAssertLessThanOrEqual(row?.fittingSize.width ?? .infinity, panel.bounds.width, "the note button is not pushed out of sight")
        }
    }
}
