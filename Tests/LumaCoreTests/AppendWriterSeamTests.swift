import PDFKit
import XCTest
@testable import LumaCore

/// Where the app and the writer meet: page numbering, the rectangles new marks get, marks written
/// straight into a page's list, and which way an underline goes.
final class AppendWriterSeamTests: XCTestCase {
    private func apply(_ changes: [MarkupChange], to bytes: [UInt8]) throws -> [UInt8] {
        [UInt8](try PDFAppendWriter.applying(changes, to: Data(bytes)))
    }

    /// Page one of the mini file, replaced: turned by `rotation`, its annotation list as given.
    private func pageOne(rotation: Int = 0, list: String, objects: [(Int, Int, String)] = []) -> [UInt8] {
        let turn = rotation == 0 ? "" : " /Rotate \(rotation)"
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\(turn) /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >> /Annots [\(list)] >>"
        return MiniPDF.update(MiniPDF().classic(), objects: [(3, 0, page)] + objects)
    }

    /// A one-page file whose text is drawn by `text` (PDF page-description language), turned by `rotation`.
    private func page(text: String, rotation: Int = 0) throws -> PDFPage {
        let stream = "BT /F1 14 Tf \(text) ET"
        let turn = rotation == 0 ? "" : " /Rotate \(rotation)"
        let base = MiniPDF().classic()
        let bytes = MiniPDF.update(base, objects: [
            (3, 0, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\(turn) /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >> >>"),
            (5, 0, "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
        ])
        return try XCTUnwrap(PDFDocument(data: Data(bytes))?.page(at: 0))
    }

    private func line(_ text: String, on page: PDFPage) throws -> CGRect {
        let all = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        return try XCTUnwrap(all.selectionsByLine().first { ($0.string ?? "").contains(text) }).bounds(for: page)
    }

    // MARK: Page numbering

    func testABranchOfThePageTreeThatMiscountsItsPagesIsRefused() {
        // Page one and two sit under a branch that says it holds one page. The system engine trusts
        // the count and shows different pages from those this writer would mark.
        func file(branchCount: String) -> [UInt8] {
            MiniPDF.update(MiniPDF().classic(), objects: [
                (2, 0, "<< /Type /Pages /Kids [10 0 R] /Count 2 >>"),
                (10, 0, "<< /Type /Pages /Parent 2 0 R /Kids [3 0 R 4 0 R]\(branchCount) >>"),
            ])
        }
        XCTAssertNil(PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data(file(branchCount: " /Count 2"))))
        XCTAssertEqual(PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data(file(branchCount: " /Count 1"))), .damaged("page tree miscounts its pages"))
        XCTAssertEqual(PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data(file(branchCount: ""))), .damaged("page tree miscounts its pages"))
        XCTAssertThrowsError(try apply([.add(MarkupAddition(pageIndex: 1, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)], red: 1, green: 1, blue: 0))],
                                       to: file(branchCount: " /Count 1")))
    }

    // MARK: Rectangles of new marks

    func testTheRectangleOfEachNewMarkIsReportedInTheOrderTheAdditionsCame() throws {
        let text = CGRect(x: 72, y: 696, width: 140, height: 20)
        let changes: [MarkupChange] = [
            .add(MarkupAddition(pageIndex: 1, kind: .underline, lineRects: [text], red: 0, green: 0, blue: 1)),
            .add(MarkupAddition(pageIndex: 0, kind: .highlight, lineRects: [text], red: 1, green: 1, blue: 0)),
        ]
        let (data, rects) = try PDFAppendWriter.applyingReportingRects(changes, to: Data(MiniPDF().classic()))
        XCTAssertEqual(rects.count, 2)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let underline = try XCTUnwrap(document.page(at: 1)?.annotations.first { $0.type == "Underline" })
        let highlight = try XCTUnwrap(document.page(at: 0)?.annotations.first { $0.type == "Highlight" })
        for (read, reported) in [(underline.bounds, rects[0]), (highlight.bounds, rects[1])] {
            XCTAssertEqual(read.minX, reported.minX, accuracy: 0.01)
            XCTAssertEqual(read.minY, reported.minY, accuracy: 0.01)
            XCTAssertEqual(read.maxX, reported.maxX, accuracy: 0.01)
            XCTAssertEqual(read.maxY, reported.maxY, accuracy: 0.01)
        }
        XCTAssertGreaterThan(rects[0].height, text.height, "an underline's rectangle reaches beyond the text")
    }

    // MARK: Marks written straight into the page's list

    private let directHighlight = "<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] /Contents (direct) /RC (<p>direct</p>) >>"
    private let directKey = ExistingMarkup(kind: .highlight, rect: CGRect(x: 100, y: 300, width: 200, height: 20))

    func testAMarkWrittenStraightIntoThePageListCanBeRecoloured() throws {
        let original = pageOne(list: "7 0 R \(directHighlight)")
        let result = try apply([.modify(page: 0, original: directKey, colour: MarkupColour(red: 1, green: 0, blue: 0), note: .unchanged),
                                .add(MarkupAddition(pageIndex: 0, kind: .underline, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)], red: 0, green: 0, blue: 1))],
                               to: original)
        XCTAssertEqual(Array(result.prefix(original.count)), original)
        let annotations = try XCTUnwrap(PDFDocument(data: Data(result))?.page(at: 0)?.annotations)
        let highlight = try XCTUnwrap(annotations.first { $0.type == "Highlight" })
        XCTAssertEqual(highlight.color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(highlight.color.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(highlight.contents, "direct")
        XCTAssertTrue(annotations.contains { $0.type == "Underline" }, "the other change in the same save is written too")
        XCTAssertTrue(annotations.contains { $0.type == "Text" && $0.contents == "old note" })
        let list = try XCTUnwrap(PDFStructure(result).object(3)["Annots"]?.array)
        XCTAssertNotNil(list[1]["RC"], "the rich-text note stays when the note is not changed")
    }

    func testANoteWrittenStraightIntoThePageListCanBeChanged() throws {
        let result = try apply([.modify(page: 0, original: directKey, colour: nil, note: .set("新的"))], to: pageOne(list: "7 0 R \(directHighlight)"))
        let list = try XCTUnwrap(PDFStructure(result).object(3)["Annots"]?.array)
        XCTAssertNil(list[1]["RC"])
        XCTAssertEqual(PDFDocument(data: Data(result))?.page(at: 0)?.annotations.first { $0.type == "Highlight" }?.contents, "新的")
    }

    func testAMarkWrittenStraightIntoThePageListCanBeRemoved() throws {
        let result = try apply([.remove(page: 0, original: directKey)], to: pageOne(list: "\(directHighlight) 7 0 R"))
        let annotations = PDFDocument(data: Data(result))?.page(at: 0)?.annotations ?? []
        XCTAssertFalse(annotations.contains { $0.type == "Highlight" })
        XCTAssertTrue(annotations.contains { $0.type == "Text" && $0.contents == "old note" })
    }

    func testTwoMarksWrittenStraightIntoTheListInTheSamePlaceAreNotChanged() {
        let original = pageOne(list: "\(directHighlight) \(directHighlight)")
        XCTAssertThrowsError(try apply([.remove(page: 0, original: directKey)], to: original)) { error in
            XCTAssertTrue("\(error)".contains("match equally"), "\(error)")
        }
    }

    // MARK: Which way an underline goes

    func testAnUnderlineFollowsTheCornersOfTextThatRunsUpThePage() {
        // Text read from bottom to top: its top faces left, so the underline is on the right.
        let up = MarkupQuad(topLeft: CGPoint(x: 100, y: 200), topRight: CGPoint(x: 100, y: 500),
                            bottomLeft: CGPoint(x: 112, y: 200), bottomRight: CGPoint(x: 112, y: 500))
        let drawing = MarkupAppearance.drawing(kind: .underline, quads: [up], red: 0, green: 0, blue: 1, corners: .asTheTextReads)
        XCTAssertTrue(drawing.content.contains("0.84 w 110.8 200 m 110.8 500 l S"), drawing.content)
        // The same corners read from a file are believed too: a line read along its longer side.
        XCTAssertEqual(MarkupAppearance.drawing(kind: .underline, quads: [up], red: 0, green: 0, blue: 1, corners: .fromAFile).content, drawing.content)
    }

    func testCornersFromAFileThatWouldPutTheLineOverTheTextAreNotBelieved() {
        // Listed top-left first but with y measured downward: the "bottom" edge they name is the top.
        let flipped = MarkupQuad(topLeft: CGPoint(x: 10, y: 20), topRight: CGPoint(x: 110, y: 20),
                                 bottomLeft: CGPoint(x: 10, y: 32), bottomRight: CGPoint(x: 110, y: 32))
        let drawing = MarkupAppearance.drawing(kind: .underline, quads: [flipped], red: 0, green: 0, blue: 1)
        XCTAssertTrue(drawing.content.contains("10 21.2 m 110 21.2 l S"), "under the text: \(drawing.content)")
        // Upright corners of a line shown turned: read along its short side, so the page's turn decides.
        let naive = MarkupQuad(CGRect(x: 100, y: 200, width: 12, height: 300))
        let turned = MarkupAppearance.drawing(kind: .underline, quads: [naive], red: 0, green: 0, blue: 1, rotation: 90)
        XCTAssertTrue(turned.content.contains("110.8 200 m 110.8 500 l S"), turned.content)
    }

    func testTheReadersCornersPutTheUnderlineUnderTextThatRunsUpOrDownThePage() throws {
        let page = try page(text: "0 1 -1 0 300 300 Tm (Vertical reading upward) Tj 0 -1 1 0 400 600 Tm (Vertical reading downward) Tj")
        for (text, side) in [("upward", 1.0), ("downward", -1.0)] {
            let box = try line(text, on: page)
            XCTAssertGreaterThan(box.height, box.width * 3, "the line runs up the page")
            let quad = PageGeometry.textQuad(forPageRect: box, on: page)
            XCTAssertEqual((quad.topRight.y - quad.topLeft.y).sign, side > 0 ? .plus : .minus, "the corners follow the reading: \(text)")
            let drawing = MarkupAppearance.drawing(kind: .underline, quads: [quad], red: 0, green: 0, blue: 1, corners: .asTheTextReads)
            // The line is vertical, near the side the letters stand on: the right for upward text, the left for downward.
            let numbers = drawing.content.split(separator: "\n").last!.split(separator: " ").compactMap { Double($0) }
            XCTAssertEqual(numbers[1], numbers[3], accuracy: 0.001, "vertical: \(drawing.content)")
            XCTAssertEqual(numbers[1], side > 0 ? box.maxX - box.width * 0.1 : box.minX + box.width * 0.1, accuracy: 0.01, text)
            XCTAssertLessThan(numbers[0], box.width * 0.1, "as thick as a share of the line's height, not of its length")
        }
    }

    func testTheReadersCornersOnATurnedPagePutTheUnderlineUnderTheTextAsShown() throws {
        // Text laid on each turned page so that it shows upright, as on a landscape page.
        for (rotation, placing) in [(90, "0 1 -1 0 300 100 Tm"), (180, "-1 0 0 -1 500 400 Tm"), (270, "0 -1 1 0 300 700 Tm")] {
            let page = try page(text: "\(placing) (Hello upright world text) Tj", rotation: rotation)
            let box = try line("Hello", on: page)
            let quad = PageGeometry.textQuad(forPageRect: box, on: page)
            let followed = segment(MarkupAppearance.drawing(kind: .underline, quads: [quad], red: 0, green: 0, blue: 1, corners: .asTheTextReads))
            let byTurn = segment(MarkupAppearance.drawing(kind: .underline, quads: [MarkupQuad(box)], red: 0, green: 0, blue: 1, rotation: rotation))
            XCTAssertEqual(followed.width, byTurn.width, accuracy: 0.002, "rotation \(rotation)")
            // The same line, drawn from either end.
            let same = { (a: (CGPoint, CGPoint), b: (CGPoint, CGPoint)) in
                hypot(a.0.x - b.0.x, a.0.y - b.0.y) < 0.01 && hypot(a.1.x - b.1.x, a.1.y - b.1.y) < 0.01 }
            XCTAssertTrue(same(followed.ends, byTurn.ends) || same(followed.ends, (byTurn.ends.1, byTurn.ends.0)), "rotation \(rotation): \(followed) \(byTurn)")
        }
    }

    func testTextShownUpsideDownIsUnderlinedTheSameWayWhenMadeAndWhenRecoloured() throws {
        // Upright on the page, but the page is shown turned half round: the line goes under it as
        // shown, both when the mark is made and when its colour is changed later.
        let page = try page(text: "72 700 Td (Hello upright world text) Tj", rotation: 180)
        let quad = PageGeometry.textQuad(forPageRect: try line("Hello", on: page), on: page)
        let made = segment(MarkupAppearance.drawing(kind: .underline, quads: [quad], red: 0, green: 0, blue: 1, rotation: 180, corners: .asTheTextReads))
        let recoloured = segment(MarkupAppearance.drawing(kind: .underline, quads: [quad], red: 0, green: 0, blue: 1, rotation: 180, corners: .fromAFile))
        XCTAssertEqual(made.ends.0.y, recoloured.ends.0.y, accuracy: 0.01)
        XCTAssertEqual(made.width, recoloured.width, accuracy: 0.001)
    }

    func testALineAcrossThePageReadsToTheRightWhateverOrderItsCharactersAreNumberedIn() throws {
        // "world" is drawn first, then "Hello" to the left of it: the left end is numbered after the
        // right end, as superscripts, citations and formulas often are.
        let page = try page(text: "150 700 Td (world) Tj -78 0 Td (Hello) Tj")
        let box = try line("world", on: page)
        XCTAssertEqual(PageGeometry.reading(ofLineAt: box, on: page), .right)
        let drawn = segment(MarkupAppearance.drawing(kind: .underline, quads: [PageGeometry.textQuad(forPageRect: box, on: page)],
                                                     red: 0, green: 0, blue: 1, corners: .asTheTextReads))
        XCTAssertLessThan(drawn.ends.0.y, box.midY, "under the words, not over them")
    }

    func testAStrayCharacterNumberedApartDoesNotTurnAColumnRound() throws {
        // A footnote mark at the top of a column reading upward, drawn before the column.
        let page = try page(text: "0 1 -1 0 300 452 Tm (1) Tj 0 1 -1 0 300 300 Tm (Vertical reading upward) Tj")
        XCTAssertEqual(PageGeometry.reading(ofLineAt: try line("upward", on: page), on: page), .up)
    }

    func testALongColumnWhoseCornersSayNothingIsUnderlinedAlongItsSide() {
        // Corners listed upright, as earlier versions and other programs write them: read along the
        // short side, so not believed. The column is underlined along its long side, thinly.
        let column = MarkupQuad(CGRect(x: 100, y: 200, width: 12, height: 300))
        let drawing = MarkupAppearance.drawing(kind: .underline, quads: [column], red: 0, green: 0, blue: 1)
        XCTAssertTrue(drawing.content.contains("0.84 w 110.8 200 m 110.8 500 l S"), drawing.content)
        // A single tall letter is still underlined beneath, and not thickly.
        let letter = MarkupAppearance.drawing(kind: .underline, quads: [MarkupQuad(CGRect(x: 100, y: 200, width: 5, height: 18))], red: 0, green: 0, blue: 1)
        XCTAssertTrue(letter.content.contains("0.5 w 100 200.5 m 105 200.5 l S"), letter.content)
    }

    // MARK: Telling which change was refused

    func testARefusedChangeIsReportedByItsPlace() {
        let original = pageOne(list: "12 0 R 13 0 R", objects: [
            (12, 0, "<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] >>"),
            (13, 0, "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /IRT 12 0 R /Contents (a reply) >>"),
        ])
        let changes: [MarkupChange] = [
            .add(MarkupAddition(pageIndex: 1, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)], red: 1, green: 1, blue: 0)),
            .remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: CGRect(x: 100, y: 300, width: 200, height: 20))),
        ]
        XCTAssertThrowsError(try apply(changes, to: original)) { error in
            XCTAssertEqual(error as? PDFAppendError, .refusedChange(1, "the annotation has replies"))
        }
    }

    func testTheSelfCheckFindsAMarkWrittenStraightIntoTheListThatWasToBeRemoved() throws {
        let original = pageOne(list: "7 0 R \(directHighlight)")
        // An update that writes the page again with the mark still in it.
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >> /Annots [7 0 R \(directHighlight)] >>"
        let out = MiniPDF.update(original, objects: [(3, 0, page)])
        let pages = try PDFStructure(original).pageNumbers()
        XCTAssertThrowsError(try PDFAppendWriter.selfCheck(out, original: original, pages: pages,
                                                           expectations: [.gone(page: 3, raw: Array(directHighlight.utf8))])) { error in
            XCTAssertTrue("\(error)".contains("still listed"), "\(error)")
        }
    }

    /// The thickness and the two ends of a one-line underline drawing.
    private func segment(_ drawing: MarkupAppearance.Drawing) -> (width: Double, ends: (CGPoint, CGPoint)) {
        let n = drawing.content.split(separator: "\n").last!.split(separator: " ").compactMap { Double($0) }
        return (n[0], (CGPoint(x: n[1], y: n[2]), CGPoint(x: n[3], y: n[4])))
    }

    func testATurnThatIsNotAQuarterTurnIsTakenAsTheSystemEngineShowsIt() throws {
        // An underline from elsewhere on upright text shown turned, with no lines of its own.
        let underline = "<< /Type /Annot /Subtype /Underline /Rect [100 200 112 500] /C [0 1 0] >>"
        for (rotation, shown) in [(45, 90), (-45, 0), (135, 180), (100, 90), (44, 0)] {
            let original = pageOne(rotation: rotation, list: "12 0 R", objects: [(12, 0, underline)])
            XCTAssertEqual(PDFDocument(data: Data(original))?.page(at: 0)?.rotation, shown, "the system engine's reading of \(rotation)")
            let key = ExistingMarkup(kind: .underline, rect: CGRect(x: 100, y: 200, width: 12, height: 300))
            let result = try apply([.modify(page: 0, original: key, colour: MarkupColour(red: 1, green: 0, blue: 0), note: .unchanged)], to: original)
            let expected = MarkupAppearance.drawing(kind: .underline, quads: [MarkupQuad(key.rect)], red: 1, green: 0, blue: 0,
                                                    rotation: shown, frame: key.rect).content
            XCTAssertTrue(String(decoding: result.suffix(result.count - original.count), as: UTF8.self).contains(expected), "rotation \(rotation)")
        }
    }
}
