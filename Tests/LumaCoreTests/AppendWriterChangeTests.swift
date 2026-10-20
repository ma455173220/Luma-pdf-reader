import PDFKit
import XCTest
@testable import LumaCore

/// Changing and removing marks that are already in the file, and how marks are drawn.
final class AppendWriterChangeTests: XCTestCase {
    private let line = CGRect(x: 72, y: 696, width: 140, height: 20)

    private func add(_ kind: MarkupAddition.Kind = .highlight, to bytes: [UInt8], note: String? = nil) throws -> [UInt8] {
        [UInt8](try PDFAppendWriter.appending([MarkupAddition(pageIndex: 0, kind: kind, lineRects: [line], red: 1, green: 0.92, blue: 0.23, note: note)], to: Data(bytes)))
    }

    private func apply(_ changes: [MarkupChange], to bytes: [UInt8]) throws -> [UInt8] {
        [UInt8](try PDFAppendWriter.applying(changes, to: Data(bytes)))
    }

    private func annotations(_ bytes: [UInt8], page: Int = 0) -> [PDFAnnotation] {
        PDFDocument(data: Data(bytes))?.page(at: page)?.annotations ?? []
    }

    private func assertRefused(_ changes: [MarkupChange], on bytes: [UInt8], because expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try apply(changes, to: bytes), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(expected), "got \(error)", file: file, line: line)
        }
    }

    /// A page carrying, besides the usual note, the given extra annotations (objects 12 onwards).
    private func pageWithExtraAnnotations(_ bodies: [String]) -> [UInt8] {
        let numbers = bodies.indices.map { 12 + $0 }
        let list = (["7 0 R"] + numbers.map { "\($0) 0 R" }).joined(separator: " ")
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >> /Annots [\(list)] >>"
        return MiniPDF.update(MiniPDF().classic(), objects: [(3, 0, page)] + zip(numbers, bodies).map { ($0, 0, $1) })
    }

    private let foreignHighlight = "<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] /Contents (from elsewhere) >>"

    // MARK: Changing

    func testOwnHighlightCanBeRecolouredAndGivenANoteInALaterSave() throws {
        let original = MiniPDF().classic()
        let once = try add(to: original)
        let twice = try apply([.modify(page: 0, original: ExistingMarkup(kind: .highlight, rect: line), colour: MarkupColour(red: 1, green: 0.4, blue: 0.4), note: .set("改过的附注"))], to: once)
        XCTAssertEqual(Array(twice.prefix(once.count)), once)
        let highlight = try XCTUnwrap(annotations(twice).first { $0.type == "Highlight" })
        XCTAssertEqual(highlight.contents, "改过的附注")
        XCTAssertEqual(highlight.color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(highlight.color.greenComponent, 0.4, accuracy: 0.01)
        XCTAssertEqual(annotations(twice).filter { $0.type == "Highlight" }.count, 1, "changed, not duplicated")
        XCTAssertTrue(annotations(twice).contains { $0.type == "Text" && $0.contents == "old note" }, "other annotations untouched")
    }

    func testRemovingANoteLeavesTheMark() throws {
        let once = try add(to: MiniPDF().classic(), note: "附注")
        let twice = try apply([.modify(page: 0, original: ExistingMarkup(kind: .highlight, rect: line), colour: MarkupColour(red: 1, green: 0.92, blue: 0.23), note: .set(nil))], to: once)
        let highlight = try XCTUnwrap(annotations(twice).first { $0.type == "Highlight" })
        XCTAssertTrue(highlight.contents?.isEmpty ?? true)
    }

    func testHighlightFromAnotherProgramCanBeChangedAndKeepsWhatItHad() throws {
        let original = pageWithExtraAnnotations([foreignHighlight])
        let result = try apply([.modify(page: 0, original: ExistingMarkup(kind: .highlight, rect: CGRect(x: 100, y: 300, width: 200, height: 20)), colour: MarkupColour(red: 0.3, green: 0.6, blue: 1), note: .set("加了附注"))], to: original)
        let highlight = try XCTUnwrap(annotations(result).first { $0.type == "Highlight" })
        XCTAssertEqual(highlight.color.blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(highlight.contents, "加了附注")
        XCTAssertEqual(highlight.bounds, CGRect(x: 100, y: 300, width: 200, height: 20), "its rectangle is kept, so it can be found again")
        let structure = try PDFStructure(result)
        XCTAssertNotNil(try structure.object(12)["AP"], "it is given a drawing of its own in the new colour")
    }

    // MARK: Removing

    func testOwnHighlightCanBeRemovedInALaterSave() throws {
        let once = try add(to: MiniPDF().classic())
        let twice = try apply([.remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: line))], to: once)
        XCTAssertFalse(annotations(twice).contains { $0.type == "Highlight" })
        XCTAssertTrue(annotations(twice).contains { $0.type == "Text" }, "only the mark goes")
        XCTAssertEqual(Array(twice.prefix(once.count)), once)
    }

    func testRemovingAHighlightAlsoRemovesItsPopUp() throws {
        let original = pageWithExtraAnnotations([
            "<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] /Popup 13 0 R >>",
            "<< /Type /Annot /Subtype /Popup /Rect [300 300 400 400] /Parent 12 0 R >>",
        ])
        let result = try apply([.remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: CGRect(x: 100, y: 300, width: 200, height: 20)))], to: original)
        let structure = try PDFStructure(result)
        let list = try structure.resolve(try structure.object(structure.pageNumbers()[0])["Annots"]!).array ?? []
        XCTAssertEqual(list.compactMap { $0.reference?.number }, [7])
    }

    func testOneSaveCanAddChangeAndRemoveTogether() throws {
        let original = pageWithExtraAnnotations([foreignHighlight])
        let once = try add(to: original)
        let changes: [MarkupChange] = [
            .remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: line)),
            .modify(page: 0, original: ExistingMarkup(kind: .highlight, rect: CGRect(x: 100, y: 300, width: 200, height: 20)), colour: MarkupColour(red: 1, green: 0.4, blue: 0.4), note: .set(nil)),
            .add(MarkupAddition(pageIndex: 1, kind: .underline, lineRects: [line], red: 0.3, green: 0.6, blue: 1)),
        ]
        let result = try apply(changes, to: once)
        XCTAssertEqual(annotations(result).filter { $0.type == "Highlight" }.count, 1)
        XCTAssertEqual(annotations(result).first { $0.type == "Highlight" }?.color.greenComponent ?? 0, 0.4, accuracy: 0.01)
        XCTAssertTrue(annotations(result, page: 1).contains { $0.type == "Underline" })
    }

    // MARK: Refusing to guess

    func testTwoIdenticalMarksAreNotChangedAtRandom() {
        let original = pageWithExtraAnnotations([foreignHighlight, foreignHighlight])
        assertRefused([.remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: CGRect(x: 100, y: 300, width: 200, height: 20)))],
                      on: original, because: "two annotations match equally")
    }

    func testMarkThatIsNotThereIsReported() {
        assertRefused([.remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: CGRect(x: 1, y: 1, width: 5, height: 5)))],
                      on: MiniPDF().classic(), because: "is not in the file")
    }

    func testAnUnderlineIsNotMistakenForAHighlight() throws {
        let once = try add(.underline, to: MiniPDF().classic())
        assertRefused([.remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: line))], on: once, because: "is not in the file")
    }

    func testTheSameMarkCannotBeChangedTwiceInOneSave() throws {
        let once = try add(to: MiniPDF().classic())
        let key = ExistingMarkup(kind: .highlight, rect: line)
        assertRefused([.modify(page: 0, original: key, colour: MarkupColour(red: 1, green: 0, blue: 0), note: .set(nil)), .remove(page: 0, original: key)],
                      on: once, because: "changed twice")
    }

    // MARK: How marks look

    func testNewHighlightCarriesItsOwnDrawing() throws {
        let result = try add(to: MiniPDF().classic())
        let structure = try PDFStructure(result)
        let list = try structure.resolve(try structure.object(structure.pageNumbers()[0])["Annots"]!).array ?? []
        let mark = try structure.resolve(list.last!)
        let drawingNumber = try XCTUnwrap(mark["AP"]?["N"]?.reference?.number)
        XCTAssertEqual(try structure.object(drawingNumber)["Subtype"]?.name, "Form")
    }

    /// A highlight must colour the page where it is, and leave the text under it readable.
    func testHighlightIsVisibleAndTheTextStaysDark() throws {
        let result = try add(to: MiniPDF().classic())
        let page = try XCTUnwrap(PDFDocument(data: Data(result))?.page(at: 0))
        let width = 612, height = 792
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            page.draw(with: .mediaBox, to: context)
        }
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let i = ((height - 1 - y) * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }
        // Inside the mark, to the right of the text: yellow.
        let empty = pixel(205, 712)
        XCTAssertGreaterThan(Int(empty.r), 200)
        XCTAssertGreaterThan(Int(empty.g), 180)
        XCTAssertLessThan(Int(empty.b), 150, "the highlight colour must show")
        // Outside the mark: still white.
        let outside = pixel(400, 400)
        XCTAssertGreaterThan(Int(outside.b), 240)
        // Under the mark there must still be dark text somewhere.
        var darkest = 255
        for x in 72..<190 { for y in 700..<712 { darkest = min(darkest, Int(pixel(x, y).g)) } }
        XCTAssertLessThan(darkest, 80, "text under the highlight must stay readable")
    }

    func testDrawingOfAHighlightFillsEachLine() {
        let drawing = MarkupAppearance.drawing(kind: .highlight, quads: [MarkupQuad(CGRect(x: 10, y: 20, width: 100, height: 12)), MarkupQuad(CGRect(x: 10, y: 5, width: 50, height: 12))],
                                               red: 1, green: 0.92, blue: 0.23)
        XCTAssertTrue(drawing.multiplies)
        XCTAssertEqual(drawing.bounds, CGRect(x: 10, y: 5, width: 100, height: 27))
        XCTAssertTrue(drawing.content.hasPrefix("/GS0 gs\n1 0.92 0.23 rg"))
        XCTAssertEqual(drawing.content.components(separatedBy: " re").count - 1, 2, "one rectangle per line")
        XCTAssertTrue(drawing.content.hasSuffix("\nf"))
    }

    func testDrawingOfAnUnderlineSitsNearTheBottomOfEachLine() {
        let drawing = MarkupAppearance.drawing(kind: .underline, quads: [MarkupQuad(CGRect(x: 10, y: 20, width: 100, height: 10))], red: 0, green: 0, blue: 1)
        XCTAssertFalse(drawing.multiplies)
        XCTAssertTrue(drawing.content.contains("0 0 1 RG"))
        XCTAssertTrue(drawing.content.contains("0.7 w 10 21 m 110 21 l S"), drawing.content)
        XCTAssertTrue(drawing.bounds.contains(CGRect(x: 10, y: 20, width: 100, height: 10)), "the line's thickness is inside the bounds")
    }

    func testDrawingOfAStrikethroughGoesThroughTheMiddleOfEachLine() {
        let drawing = MarkupAppearance.drawing(kind: .strikeOut, quads: [MarkupQuad(CGRect(x: 10, y: 20, width: 100, height: 10))], red: 1, green: 0, blue: 0)
        XCTAssertFalse(drawing.multiplies)
        XCTAssertTrue(drawing.content.contains("1 0 0 RG"))
        XCTAssertTrue(drawing.content.contains("0.7 w 10 24.5 m 110 24.5 l S"), drawing.content)
        XCTAssertTrue(drawing.bounds.contains(CGRect(x: 10, y: 20, width: 100, height: 10)))
    }

    func testStrikethroughsAreSavedAsStrikeOutAndCanBeChangedAndRemoved() throws {
        let once = try add(.strikeOut, to: MiniPDF().classic())
        XCTAssertTrue(annotations(once).contains { $0.type == "StrikeOut" }, "a standard StrikeOut annotation, which other readers show")
        let key = ExistingMarkup(kind: .strikeOut, rect: MarkupAppearance.drawing(kind: .strikeOut, quads: [MarkupQuad(line)], red: 0, green: 0, blue: 0).bounds)
        assertRefused([.remove(page: 0, original: ExistingMarkup(kind: .underline, rect: key.rect))], on: once, because: "is not in the file")
        let twice = try apply([.modify(page: 0, original: key, colour: MarkupColour(red: 0, green: 0, blue: 1), note: .set("删除线附注"))], to: once)
        XCTAssertEqual(annotations(twice).first { $0.type == "StrikeOut" }?.contents, "删除线附注")
        let thrice = try apply([.remove(page: 0, original: key)], to: twice)
        XCTAssertFalse(annotations(thrice).contains { $0.type == "StrikeOut" })
    }

    func testNumbersAreWrittenCompactly() {
        XCTAssertEqual(MarkupAppearance.number(12), "12")
        XCTAssertEqual(MarkupAppearance.number(0.5), "0.5")
        XCTAssertEqual(MarkupAppearance.number(1.23456), "1.235")
        XCTAssertEqual(MarkupAppearance.number(-0.0001), "0")
    }

    func testQuadsAreReadBackFromAFlatList() {
        XCTAssertEqual(MarkupQuad.quads(from: [0, 10, 20, 10, 0, 0, 20, 0]), [MarkupQuad(CGRect(x: 0, y: 0, width: 20, height: 10))])
        XCTAssertNil(MarkupQuad.quads(from: [1, 2, 3]))
        XCTAssertNil(MarkupQuad.quads(from: []))
    }

    // MARK: Telling the reader early

    func testFilesThatCannotTakeAnnotationsAreReportedBeforeAnythingIsMarked() {
        XCTAssertNil(PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data(MiniPDF().classic())))
        var signed = MiniPDF()
        signed.catalogExtras = MiniPDF.formSayingSignaturesExist
        XCTAssertEqual(PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data(signed.classic())), .refused("digitally signed"))
        var locked = MiniPDF()
        locked.encrypted = true
        XCTAssertEqual(PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data(locked.classic())), .refused("password-protected"))
        XCTAssertNotNil(PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data("not a pdf".utf8)))
    }

    func testTheCheckReadStraightFromTheFileGivesTheSameAnswers() throws {
        var signed = MiniPDF()
        signed.catalogExtras = MiniPDF.formSayingSignaturesExist
        let whole = MiniPDF().classic()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, bytes) in [("plain", whole), ("signed", signed.classic()), ("cut short", Array(whole.prefix(whole.count / 2))), ("empty", [])] {
            let file = folder.appendingPathComponent(name + ".pdf")
            try Data(bytes).write(to: file)
            XCTAssertEqual(PDFAppendWriter.reasonAnnotationsCannotBeSaved(file: file), PDFAppendWriter.reasonAnnotationsCannotBeSaved(Data(bytes)), name)
        }
        XCTAssertEqual(PDFAppendWriter.reasonAnnotationsCannotBeSaved(file: folder.appendingPathComponent("missing.pdf")), .damaged("file could not be read"))
    }

    // MARK: What a change leaves alone

    private let foreignRect = CGRect(x: 100, y: 300, width: 200, height: 20)
    private func foreignKey(_ kind: MarkupAddition.Kind = .highlight) -> ExistingMarkup { ExistingMarkup(kind: kind, rect: foreignRect) }

    func testChangingOnlyTheColourKeepsTheNoteByteForByte() throws {
        // A note written as UTF-8 (allowed since PDF 2.0), which the system engine does not decode.
        let original = pageWithExtraAnnotations(["<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] /Contents <EFBBBFE4BDA0E5A5BD> /RC (<p>你好</p>) >>"])
        let result = try apply([.modify(page: 0, original: foreignKey(), colour: MarkupColour(red: 1, green: 0, blue: 0), note: .unchanged)], to: original)
        let changed = try PDFStructure(result).object(12)
        XCTAssertEqual(changed["Contents"].map { String(decoding: Array($0.raw), as: UTF8.self) }, "<EFBBBFE4BDA0E5A5BD>")
        XCTAssertNotNil(changed["RC"], "a rich-text note stays when the note is not changed")
    }

    func testChangingOnlyTheNoteKeepsTheColourAndDrawing() throws {
        let original = pageWithExtraAnnotations(["<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] /AP << /N 13 0 R >> >>",
                                                 "<< /Type /XObject /Subtype /Form /BBox [100 300 300 320] /Length 0 >>\nstream\n\nendstream"])
        let result = try apply([.modify(page: 0, original: foreignKey(), colour: nil, note: .set("新附注"))], to: original)
        let changed = try PDFStructure(result).object(12)
        XCTAssertEqual(changed["C"].map { String(decoding: Array($0.raw), as: UTF8.self) }, "[0 1 0]")
        XCTAssertEqual(changed["AP"]?["N"]?.reference?.number, 13, "its own drawing is kept")
    }

    func testANewNoteRemovesAnOldRichTextNote() throws {
        let original = pageWithExtraAnnotations(["<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] /Contents (old) /RC (<p>old</p>) >>"])
        let result = try apply([.modify(page: 0, original: foreignKey(), colour: nil, note: .set("new"))], to: original)
        XCTAssertNil(try PDFStructure(result).object(12)["RC"])
    }

    func testANewColourIsDrawnInsideTheRectangleTheMarkAlreadyHas() throws {
        // Lines listed in another corner order, and a rectangle wider than the lines.
        let original = pageWithExtraAnnotations(["<< /Type /Annot /Subtype /Highlight /Rect [80 300 320 320] /QuadPoints [100 300 300 300 300 320 100 320] /C [0 1 0] >>"])
        let key = ExistingMarkup(kind: .highlight, rect: CGRect(x: 80, y: 300, width: 240, height: 20))
        let result = try apply([.modify(page: 0, original: key, colour: MarkupColour(red: 1, green: 0, blue: 0), note: .unchanged)], to: original)
        let structure = try PDFStructure(result)
        let drawingNumber = try XCTUnwrap(structure.object(12)["AP"]?["N"]?.reference?.number)
        let drawing = try structure.object(drawingNumber)
        XCTAssertEqual(drawing["BBox"]?.array?.compactMap(\.number), [80, 300, 320, 320], "declared over the rectangle, so nothing is stretched")
    }

    func testDrawingUsesEachLinesBoxWhateverTheCornerOrder() {
        let bottomFirst = MarkupQuad(topLeft: CGPoint(x: 10, y: 20), topRight: CGPoint(x: 110, y: 20), bottomLeft: CGPoint(x: 110, y: 32), bottomRight: CGPoint(x: 10, y: 32))
        let highlight = MarkupAppearance.drawing(kind: .highlight, quads: [bottomFirst], red: 1, green: 1, blue: 0)
        XCTAssertTrue(highlight.content.contains("10 20 100 12 re"), highlight.content)
        let underline = MarkupAppearance.drawing(kind: .underline, quads: [bottomFirst], red: 0, green: 0, blue: 1)
        XCTAssertTrue(underline.content.contains("10 21.2 m 110 21.2 l S"), "under the text, not over it: \(underline.content)")
    }

    func testAnUnderlineOnATurnedPageIsUnderTheTextAsShown() {
        let line = MarkupQuad(CGRect(x: 100, y: 200, width: 12, height: 300))      // text running up the page, shown turned 90°
        let drawing = MarkupAppearance.drawing(kind: .underline, quads: [line], red: 0, green: 0, blue: 1, rotation: 90)
        XCTAssertTrue(drawing.content.contains("110.8 200 m 110.8 500 l S"), drawing.content)
    }

    func testAbsurdLinesFallBackToTheRectangle() throws {
        let original = pageWithExtraAnnotations(["<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /QuadPoints [1e300 1 2 3 4 5 6 7] /C [0 1 0] >>"])
        let result = try apply([.modify(page: 0, original: foreignKey(), colour: MarkupColour(red: 1, green: 0, blue: 0), note: .unchanged)], to: original)
        XCTAssertFalse(String(decoding: result.suffix(result.count - original.count), as: UTF8.self).contains("inf"))
    }

    // MARK: What a removal leaves alone

    func testRemovingAMarkKeepsAnotherAnnotationItsPopUpEntryPointsTo() throws {
        // A malformed /Popup that points at the page's own text note rather than at a pop-up window.
        let original = pageWithExtraAnnotations(["<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] /Popup 7 0 R >>"])
        let result = try apply([.remove(page: 0, original: foreignKey())], to: original)
        XCTAssertTrue(annotations(result).contains { $0.type == "Text" && $0.contents == "old note" })
        XCTAssertFalse(annotations(result).contains { $0.type == "Highlight" })
    }

    func testRemovingAMarkWithAReplyIsRefused() {
        let original = pageWithExtraAnnotations(["<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] >>",
                                                 "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /IRT 12 0 R /Contents (a reply) >>"])
        assertRefused([.remove(page: 0, original: foreignKey())], on: original, because: "has replies")
    }

    func testAMarkListedOnTwoPagesCannotBeChangedTwice() {
        let pageOne = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >> /Annots [7 0 R 12 0 R] >>"
        let pageTwo = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 9 0 R >> >> /Annots [12 0 R] >>"
        let original = MiniPDF.update(MiniPDF().classic(), objects: [(3, 0, pageOne), (4, 0, pageTwo),
                                                                     (12, 0, "<< /Type /Annot /Subtype /Highlight /Rect [100 300 300 320] /C [0 1 0] >>")])
        assertRefused([.modify(page: 0, original: foreignKey(), colour: MarkupColour(red: 1, green: 0, blue: 0), note: .unchanged),
                       .modify(page: 1, original: foreignKey(), colour: MarkupColour(red: 0, green: 0, blue: 1), note: .unchanged)],
                      on: original, because: "changed twice")
    }

    func testUnderlinesCanBeChangedAndRemovedOnThePageTheyAreOn() throws {
        let once = try add(.underline, to: MiniPDF().classic())
        let key = ExistingMarkup(kind: .underline, rect: MarkupAppearance.drawing(kind: .underline, quads: [MarkupQuad(line)], red: 0, green: 0, blue: 0).bounds)
        let twice = try apply([.modify(page: 0, original: key, colour: MarkupColour(red: 0, green: 0, blue: 1), note: .set("下划线附注"))], to: once)
        XCTAssertEqual(annotations(twice).first { $0.type == "Underline" }?.contents, "下划线附注")
        let thrice = try apply([.remove(page: 0, original: key)], to: twice)
        XCTAssertFalse(annotations(thrice).contains { $0.type == "Underline" })
    }

    func testMarksInACompressedIndexedFileCanBeChangedAndRemoved() throws {
        let once = [UInt8](try PDFAppendWriter.appending([MarkupAddition(pageIndex: 1, lineRects: [line], red: 1, green: 0.92, blue: 0.23)], to: Data(MiniPDF().compressed())))
        let key = ExistingMarkup(kind: .highlight, rect: line)
        let twice = try apply([.modify(page: 1, original: key, colour: MarkupColour(red: 0, green: 1, blue: 0), note: .set("压缩索引"))], to: once)
        XCTAssertEqual(annotations(twice, page: 1).first { $0.type == "Highlight" }?.contents, "压缩索引")
        let thrice = try apply([.remove(page: 1, original: key)], to: twice)
        XCTAssertFalse(annotations(thrice, page: 1).contains { $0.type == "Highlight" })
    }
}
