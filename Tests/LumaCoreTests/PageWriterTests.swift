import PDFKit
import XCTest
@testable import LumaCore

/// Builds a PDF with an old-style index from numbered object bodies. Object 1 must be the catalog.
private func classicPDF(_ objects: [(Int, String)]) -> [UInt8] {
    var out = Array("%PDF-1.7\n".utf8)
    var offsets: [Int: Int] = [:]
    for (number, body) in objects.sorted(by: { $0.0 < $1.0 }) {
        offsets[number] = out.count
        out += Array("\(number) 0 obj\n\(body)\nendobj\n".utf8)
    }
    let size = (offsets.keys.max() ?? 0) + 1
    let start = out.count
    out += Array("xref\n0 \(size)\n".utf8)
    for number in 0..<size {
        if let offset = offsets[number] {
            out += Array("\(MiniPDF.padded(offset, 10)) 00000 n \n".utf8)
        } else {
            out += Array("0000000000 \(number == 0 ? "65535" : "00000") f \n".utf8)
        }
    }
    out += Array("trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8)
    return out
}

private extension Array where Element == UInt8 {
    /// The same file with the branch's "/Parent 2 0 R" pointing elsewhere (a one-digit number keeps the
    /// length, so the index stays right).
    func replacingParent(of branch: Int, with node: Int) -> [UInt8] {
        let text = String(decoding: self, as: UTF8.self)
        let marker = "\(branch) 0 obj\n<< /Type /Pages /Parent 2 0 R"
        return Array(text.replacingOccurrences(of: marker, with: "\(branch) 0 obj\n<< /Type /Pages /Parent \(node) 0 R").utf8)
    }
}

private func contentStream(_ text: String) -> String {
    let stream = "BT /F1 18 Tf 72 400 Td (\(text)) Tj ET"
    return "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
}

/// Four pages in two branches. The first branch gives its pages their resources, a smaller size and
/// a quarter turn; the second gives nothing, so its pages take the root's size.
///
/// 1 catalog, 2 root, 3 and 4 branches, 5–8 pages "Page A" to "Page D", 9–12 their contents, 13 font.
private func twoBranchPDF(catalogExtras: String = "", pageExtras: [Int: String] = [:], extraObjects: [(Int, String)] = [],
                          parentOverride: [Int: Int] = [:]) -> [UInt8] {
    var objects: [(Int, String)] = [
        (1, "<< /Type /Catalog /Pages 2 0 R\(catalogExtras) >>"),
        (2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 4 /MediaBox [0 0 612 792] >>"),
        (3, "<< /Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2 /Resources << /Font << /F1 13 0 R >> >> /MediaBox [0 0 400 600] /Rotate 90 >>"),
        (4, "<< /Type /Pages /Parent 2 0 R /Kids [7 0 R 8 0 R] /Count 2 >>"),
        (13, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
    ]
    for (k, letter) in ["A", "B", "C", "D"].enumerated() {
        let number = 5 + k
        let parent = parentOverride[k] ?? (k < 2 ? 3 : 4)
        let resources = k < 2 ? "" : " /Resources << /Font << /F1 13 0 R >> >>"
        objects.append((number, "<< /Type /Page /Parent \(parent) 0 R /Contents \(9 + k) 0 R\(resources)\(pageExtras[k] ?? "") >>"))
        objects.append((9 + k, contentStream("Page \(letter)")))
    }
    return classicPDF(objects + extraObjects)
}

final class PageWriterTests: XCTestCase {

    private func apply(_ slots: [PageSlot], to bytes: [UInt8], sources: [[UInt8]] = []) throws -> [UInt8] {
        [UInt8](try PDFPageWriter.applying(slots, sources: sources.map { Data($0) }, to: Data(bytes)))
    }

    private func document(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: Data(bytes)), "system engine cannot open the result", file: file, line: line)
    }

    private func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func assertRefused(_ slots: [PageSlot], _ bytes: [UInt8], sources: [[UInt8]] = [], because expected: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try apply(slots, to: bytes, sources: sources), "was accepted", file: file, line: line) { error in
            guard let error = error as? PDFAppendError else { return XCTFail("unexpected error \(error)", file: file, line: line) }
            if case .selfCheckFailed = error { XCTFail("writer rejected its own output: \(error)", file: file, line: line) }
            XCTAssertTrue(error.description.contains(expected), "refused for another reason: \(error)", file: file, line: line)
        }
    }

    private func originalSlots(_ count: Int, rotations: [Int: Int] = [:]) -> [PageSlot] {
        (0..<count).map { PageSlot(.original($0), rotation: rotations[$0] ?? 0) }
    }

    // MARK: Turning

    func testTurningOnePageChangesOnlyItsTurn() throws {
        for original in [MiniPDF().classic(), MiniPDF().compressed(), MiniPDF().compressed(usePredictor: true)] {
            let result = try apply(originalSlots(2, rotations: [0: 90]), to: original)
            XCTAssertEqual(Array(result.prefix(original.count)), original)
            let before = try document(original), after = try document(result)
            XCTAssertEqual(after.page(at: 0)?.rotation, 90)
            XCTAssertEqual(after.page(at: 1)?.rotation, 0)
            XCTAssertEqual(texts(after), texts(before))
            XCTAssertEqual(after.page(at: 0)?.annotations.count, 1, "the note stays")
            XCTAssertEqual(after.page(at: 0)?.bounds(for: .mediaBox), before.page(at: 0)?.bounds(for: .mediaBox))
            // Only page one is written again.
            let structure = try PDFStructure(result)
            XCTAssertEqual(try PDFPageWriter.rotations(of: Data(result)), [90, 0])
            XCTAssertEqual(structure.sectionCount, 2)
        }
    }

    func testTurningBackToUpright() throws {
        var file = MiniPDF()
        file.rotation = 270
        let original = file.classic()
        XCTAssertEqual(try PDFPageWriter.rotations(of: Data(original)), [270, 0])
        let result = try apply(originalSlots(2), to: original)
        XCTAssertEqual(try document(result).page(at: 0)?.rotation, 0)
    }

    func testNothingToDoLeavesTheFileAlone() throws {
        var file = MiniPDF()
        file.rotation = 90
        let original = file.classic()
        XCTAssertEqual(try apply(originalSlots(2, rotations: [0: 90]), to: original), original)
    }

    func testTurningAPageThatTakesItsTurnFromTheTree() throws {
        let original = twoBranchPDF()
        XCTAssertEqual(try PDFPageWriter.rotations(of: Data(original)), [90, 90, 0, 0])
        let result = try apply([PageSlot(.original(0), rotation: 0), PageSlot(.original(1), rotation: 180),
                                PageSlot(.original(2), rotation: 0), PageSlot(.original(3), rotation: 270)], to: original)
        let after = try document(result)
        XCTAssertEqual((0..<4).map { after.page(at: $0)?.rotation }, [0, 180, 0, 270])
        XCTAssertEqual(texts(after), ["Page A", "Page B", "Page C", "Page D"])
    }

    func testTurnsOnTopOfTurns() throws {
        let original = MiniPDF().compressed()
        let first = try apply(originalSlots(2, rotations: [0: 90, 1: 180]), to: original)
        let second = try apply(originalSlots(2, rotations: [0: 270, 1: 180]), to: first)
        XCTAssertEqual(Array(second.prefix(first.count)), first)
        let after = try document(second)
        XCTAssertEqual([after.page(at: 0)?.rotation, after.page(at: 1)?.rotation], [270, 180])
    }

    func testMarksGoOnATurnedPage() throws {
        let turned = try apply(originalSlots(2, rotations: [1: 90]), to: MiniPDF().classic())
        let marked = try PDFAppendWriter.appending([MarkupAddition(pageIndex: 1, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)],
                                                                   red: 1, green: 1, blue: 0, note: "知白")], to: Data(turned))
        let after = try document([UInt8](marked))
        XCTAssertEqual(after.page(at: 1)?.rotation, 90)
        XCTAssertTrue(after.page(at: 1)?.annotations.contains { $0.type == "Highlight" && $0.contents == "知白" } ?? false)
    }

    // MARK: What is refused

    func testNonsenseIsRefused() {
        let original = MiniPDF().classic()
        assertRefused([], original, because: "at least one page")
        assertRefused([PageSlot(.original(0), rotation: 45)], original, because: "quarter turns")
        assertRefused([PageSlot(.original(0), rotation: 0), PageSlot(.original(0), rotation: 0)], original, because: "listed twice")
        assertRefused([PageSlot(.original(2), rotation: 0)], original, because: "does not exist")
        assertRefused([PageSlot(.inserted(source: 0, page: 0), rotation: 0)], original, because: "insert from is missing")
        assertRefused([PageSlot(.inserted(source: 0, page: 5), rotation: 0)], original, sources: [MiniPDF().classic()], because: "page to insert does not exist")
    }

    func testFilesTheAnnotationWriterRefusesAreRefusedToo() {
        var locked = MiniPDF()
        locked.encrypted = true
        assertRefused(originalSlots(2, rotations: [0: 90]), locked.classic(), because: "password-protected")
        var signed = MiniPDF()
        signed.catalogExtras = MiniPDF.certification
        assertRefused(originalSlots(2, rotations: [0: 90]), signed.classic(), because: "certified")
        var miscounted = MiniPDF()
        miscounted.declaredPageCount = 3
        assertRefused(originalSlots(2, rotations: [0: 90]), miscounted.classic(), because: "miscounts")
    }

    // MARK: Removing and reordering

    func testRemovingAPage() throws {
        for original in [MiniPDF().classic(), MiniPDF().compressed()] {
            let result = try apply([PageSlot(.original(1), rotation: 0)], to: original)
            XCTAssertEqual(Array(result.prefix(original.count)), original)
            let after = try document(result)
            XCTAssertEqual(texts(after), ["Hello page two"])
            // Still in the file: the removed page's contents were not touched.
            XCTAssertNotNil(try PDFStructure(result).object(3).entries)
        }
    }

    func testReordering() throws {
        let original = MiniPDF().classic()
        let result = try apply([PageSlot(.original(1), rotation: 0), PageSlot(.original(0), rotation: 0)], to: original)
        let after = try document(result)
        XCTAssertEqual(texts(after), ["Hello page two", "Hello page one"])
        XCTAssertEqual(after.page(at: 1)?.annotations.first?.contents, "old note")
    }

    func testReorderingAcrossBranchesKeepsWhatPagesTookFromTheirBranch() throws {
        let original = twoBranchPDF()
        let before = try document(original)
        let order = [3, 0, 2, 1]
        let result = try apply(order.map { PageSlot(.original($0), rotation: [90, 90, 0, 0][$0]) }, to: original)
        let after = try document(result)
        XCTAssertEqual(texts(after), order.map { texts(before)[$0] })
        for (k, index) in order.enumerated() {
            XCTAssertEqual(after.page(at: k)?.rotation, before.page(at: index)?.rotation, "turn of \(texts(before)[index])")
            XCTAssertEqual(after.page(at: k)?.bounds(for: .mediaBox), before.page(at: index)?.bounds(for: .mediaBox), "size of \(texts(before)[index])")
        }
        // The tree is now flat: every page hangs from the root.
        let structure = try PDFStructure(result)
        XCTAssertEqual(try structure.listingParents().values.map { $0 }, [2, 2, 2, 2])
        for number in try structure.pageNumbers() { XCTAssertEqual(try structure.object(number)["Parent"]?.reference?.number, 2) }
    }

    func testRemovingAndTurningTogether() throws {
        let original = twoBranchPDF()
        let result = try apply([PageSlot(.original(1), rotation: 0), PageSlot(.original(2), rotation: 90)], to: original)
        let after = try document(result)
        XCTAssertEqual(texts(after), ["Page B", "Page C"])
        XCTAssertEqual([after.page(at: 0)?.rotation, after.page(at: 1)?.rotation], [0, 90])
        XCTAssertEqual(after.page(at: 0)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 400, height: 600))
    }

    func testOutlineLinksAndOpeningViewNoLongerLeadToARemovedPage() throws {
        // Outline: 20 root, 21 → page B (explicit), 22 → page C (named, name tree), 23 → page B by a "go to" action.
        // Links on page A: 24 → page B, 25 → page D. Opening view on page B.
        let original = twoBranchPDF(
            catalogExtras: " /Outlines 20 0 R /Names << /Dests 26 0 R >> /OpenAction [6 0 R /Fit]",
            pageExtras: [0: " /Annots [24 0 R 25 0 R << /Type /Annot /Subtype /Link /Rect [0 0 9 9] /Dest [6 0 R /Fit] >>]"],
            extraObjects: [
                (20, "<< /Type /Outlines /First 21 0 R /Last 23 0 R /Count 3 >>"),
                (21, "<< /Title (One) /Parent 20 0 R /Next 22 0 R /Dest [6 0 R /XYZ 0 792 0] >>"),
                (22, "<< /Title (Two) /Parent 20 0 R /Prev 21 0 R /Next 23 0 R /Dest (sec\\0612) >>"),
                (23, "<< /Title (Three) /Parent 20 0 R /Prev 22 0 R /A << /S /GoTo /D [6 0 R /Fit] >> >>"),
                (24, "<< /Type /Annot /Subtype /Link /Rect [72 72 144 90] /Dest [6 0 R /Fit] >>"),
                (25, "<< /Type /Annot /Subtype /Link /Rect [72 100 144 120] /A << /S /GoTo /D [8 0 R /Fit] >> >>"),
                (26, "<< /Names [<73656331> [7 0 R /Fit] (sec12) [7 0 R /Fit]] >>"),
            ])
        // Remove pages B and C.
        let result = try apply([PageSlot(.original(0), rotation: 90), PageSlot(.original(3), rotation: 0)], to: original)
        let structure = try PDFStructure(result)
        XCTAssertNil(try structure.object(21)["Dest"])
        XCTAssertNil(try structure.object(22)["Dest"])
        XCTAssertNil(try structure.object(23)["A"])
        XCTAssertEqual(try structure.object(21)["Title"].map { Array($0.raw) }, Array("(One)".utf8), "entry keeps its title")
        XCTAssertNil(try structure.object(24)["Dest"])
        XCTAssertNotNil(try structure.object(25)["A"], "a link to a page that stays keeps its way")
        XCTAssertNil(try structure.catalog()["OpenAction"])
        XCTAssertNotNil(try structure.catalog()["Outlines"])
        let inline = try structure.object(5)["Annots"]?.array?[2]
        XCTAssertEqual(inline?["Subtype"]?.name, "Link")
        XCTAssertNil(inline?["Dest"])
        let after = try document(result)
        XCTAssertEqual(texts(after), ["Page A", "Page D"])
        XCTAssertEqual(after.page(at: 0)?.annotations.count, 3)
        XCTAssertEqual(after.outlineRoot?.numberOfChildren, 3)
    }

    // MARK: Inserting

    /// A source with a note, a web link, a link within itself, a form field and a pop-up of the field.
    private func sourceWithAnnotations() -> [UInt8] {
        var file = MiniPDF()
        file.annotations = .none
        file.pageExtras = " /Annots [7 0 R 20 0 R 21 0 R 22 0 R 23 0 R] /StructParents 0"
        file.catalogExtras = " /StructTreeRoot 24 0 R"
        file.extraObjects = [
            (20, 0, "<< /Type /Annot /Subtype /Link /Rect [72 72 144 90] /P 3 0 R /A << /S /URI /URI (https://example.org) >> >>"),
            (21, 0, "<< /Type /Annot /Subtype /Link /Rect [72 100 144 120] /Dest [4 0 R /Fit] >>"),
            (22, 0, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 200 200 220] /P 3 0 R /Popup 23 0 R >>"),
            (23, 0, "<< /Type /Annot /Subtype /Popup /Rect [72 300 200 320] /Parent 22 0 R >>"),
            (24, 0, "<< /Type /StructTreeRoot /K [] >>"),
        ]
        return file.classic()
    }

    func testInsertingAPageFromAnotherDocument() throws {
        let original = twoBranchPDF()
        let source = sourceWithAnnotations()
        let result = try apply(originalSlots(4, rotations: [0: 90, 1: 90]) + [PageSlot(.inserted(source: 0, page: 0), rotation: 0)],
                               to: original, sources: [source])
        XCTAssertEqual(Array(result.prefix(original.count)), original)
        let after = try document(result)
        XCTAssertEqual(texts(after), ["Page A", "Page B", "Page C", "Page D", "Hello page one"])
        let inserted = try XCTUnwrap(after.page(at: 4))
        XCTAssertEqual(inserted.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
        let kinds = inserted.annotations.map { $0.type ?? "?" }.sorted()
        XCTAssertEqual(kinds, ["Link", "Text"], "the note and the web link come along; the link within, the field and its pop-up do not")
        XCTAssertEqual(inserted.annotations.first { $0.type == "Text" }?.contents, "old note")
        // Nothing of the other document as a whole came along.
        let structure = try PDFStructure(result)
        let page = try structure.object(try structure.pageNumbers()[4])
        XCTAssertNil(page["StructParents"])
        XCTAssertEqual(page["Parent"]?.reference?.number, 2)
        // The web link's back-reference names the new page.
        let link = try structure.resolve(page["Annots"]!.array!.first { try! structure.resolve($0)["Subtype"]?.name == "Link" }!)
        XCTAssertEqual(link["P"]?.reference?.number, try structure.pageNumbers()[4])
    }

    func testInsertingFromAPackedDocumentAndTwiceTheSamePage() throws {
        let original = MiniPDF().classic()
        let source = MiniPDF().compressed(usePredictor: true)
        let slots = [PageSlot(.inserted(source: 0, page: 1), rotation: 90), PageSlot(.original(0), rotation: 0),
                     PageSlot(.inserted(source: 0, page: 1), rotation: 0), PageSlot(.inserted(source: 0, page: 0), rotation: 0),
                     PageSlot(.original(1), rotation: 0)]
        let result = try apply(slots, to: original, sources: [source])
        let after = try document(result)
        XCTAssertEqual(texts(after), ["Hello page two", "Hello page one", "Hello page two", "Hello page one", "Hello page two"])
        XCTAssertEqual(after.page(at: 0)?.rotation, 90)
        XCTAssertEqual(after.page(at: 2)?.rotation, 0)
        let structure = try PDFStructure(result)
        XCTAssertEqual(Set(try structure.pageNumbers()).count, 5, "every page is its own object")
    }

    func testMergingAWholeDocumentAndMarkingIt() throws {
        let original = MiniPDF().compressed()
        let source = twoBranchPDF()
        let slots = originalSlots(2) + (0..<4).map { PageSlot(.inserted(source: 0, page: $0), rotation: [90, 90, 0, 0][$0]) }
        let merged = try apply(slots, to: original, sources: [source])
        let marked = try PDFAppendWriter.appending([MarkupAddition(pageIndex: 5, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)],
                                                                   red: 1, green: 1, blue: 0)], to: Data(merged))
        let after = try document([UInt8](marked))
        XCTAssertEqual(texts(after), ["Hello page one", "Hello page two", "Page A", "Page B", "Page C", "Page D"])
        XCTAssertEqual(after.page(at: 2)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 400, height: 600))
        XCTAssertEqual(after.page(at: 4)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
        XCTAssertTrue(after.page(at: 5)?.annotations.contains { $0.type == "Highlight" } ?? false)
        // Then remove one of the merged pages and one of the file's own.
        let trimmed = try apply([PageSlot(.original(1), rotation: 0), PageSlot(.original(2), rotation: 90), PageSlot(.original(5), rotation: 0)],
                                to: [UInt8](marked))
        XCTAssertEqual(texts(try document(trimmed)), ["Hello page two", "Page A", "Page D"])
    }

    func testDocumentsThatCannotBeInsertedFrom() {
        var locked = MiniPDF()
        locked.encrypted = true
        XCTAssertNotNil(PDFPageWriter.reasonPagesCannotBeInserted(from: Data(locked.classic())))
        assertRefused(originalSlots(2) + [PageSlot(.inserted(source: 0, page: 0), rotation: 0)], MiniPDF().classic(),
                      sources: [locked.classic()], because: "insert from is password-protected")
        XCTAssertNil(PDFPageWriter.reasonPagesCannotBeInserted(from: Data(MiniPDF().compressed())))
        var broken = MiniPDF()
        broken.swappedIndexEntries = (5, 6)
        assertRefused(originalSlots(2) + [PageSlot(.inserted(source: 0, page: 0), rotation: 0)], MiniPDF().classic(),
                      sources: [broken.classic()], because: "wrong object")
    }

    func testLayersAreNotCarriedOver() {
        var source = MiniPDF()
        source.pageExtras = " /Group << /OC 20 0 R >>"
        source.extraObjects = [(20, 0, "<< /Type /OCG /Name (layer) >>")]
        assertRefused(originalSlots(2) + [PageSlot(.inserted(source: 0, page: 0), rotation: 0)], MiniPDF().classic(),
                      sources: [source.classic()], because: "layers")
        // Told when the file is dropped in, not only when saving.
        XCTAssertEqual(PDFPageWriter.reasonPagesCannotBeInserted(from: Data(source.classic())),
                       .refused("the pages to insert use layers, which cannot be carried over"))
    }

    func testStringsAreReadAsTheyAreMeant() {
        XCTAssertEqual(PDFStrings.bytes(ArraySlice(Array("(a\\(b\\)\\\\c\\061\\n)".utf8))), Array("a(b)\\c1\n".utf8))
        XCTAssertEqual(PDFStrings.bytes(ArraySlice(Array("<73 6563 3>".utf8))), [0x73, 0x65, 0x63, 0x30])
        XCTAssertNil(PDFStrings.bytes(ArraySlice(Array("/name".utf8))))
    }

    // MARK: Slim copies

    private func occurrences(of text: String, in bytes: [UInt8]) -> Int {
        let needle = Array(text.utf8)
        guard bytes.count >= needle.count else { return 0 }
        return (0...(bytes.count - needle.count)).filter { Array(bytes[$0..<($0 + needle.count)]) == needle }.count
    }

    func testASlimCopyShowsWhatTheFileShows() throws {
        for original in [MiniPDF().classic(), MiniPDF().compressed(usePredictor: true), twoBranchPDF()] {
            let copy = [UInt8](try PDFSlimCopy.making(from: Data(original)))
            let before = try document(original), after = try document(copy)
            XCTAssertEqual(texts(after), texts(before))
            for k in 0..<before.pageCount {
                XCTAssertEqual(after.page(at: k)?.rotation, before.page(at: k)?.rotation)
                XCTAssertEqual(after.page(at: k)?.bounds(for: .mediaBox), before.page(at: k)?.bounds(for: .mediaBox))
                XCTAssertEqual(after.page(at: k)?.annotations.map { $0.contents ?? "" }, before.page(at: k)?.annotations.map { $0.contents ?? "" })
            }
            XCTAssertEqual(try PDFStructure(copy).sectionCount, 1, "a new file with a single index")
        }
    }

    func testASlimCopyLeavesRemovedPagesOut() throws {
        let original = MiniPDF().classic()
        let trimmed = try apply([PageSlot(.original(1), rotation: 90)], to: original)
        XCTAssertEqual(occurrences(of: "Hello page one", in: trimmed), 1, "the removed page is still in the appended file")
        let copy = [UInt8](try PDFSlimCopy.making(from: Data(trimmed)))
        XCTAssertEqual(occurrences(of: "Hello page one", in: copy), 0)
        XCTAssertLessThan(copy.count, trimmed.count)
        let after = try document(copy)
        XCTAssertEqual(texts(after), ["Hello page two"])
        XCTAssertEqual(after.page(at: 0)?.rotation, 90)
    }

    func testASlimCopyKeepsOutlineLinksFormAndNames() throws {
        let original = twoBranchPDF(
            catalogExtras: " /Outlines 20 0 R /Names << /Dests 26 0 R >> /AcroForm << /Fields [27 0 R] >> /StructTreeRoot 28 0 R",
            pageExtras: [0: " /Annots [24 0 R 25 0 R 27 0 R] /StructParents 0"],
            extraObjects: [
                (20, "<< /Type /Outlines /First 21 0 R /Last 21 0 R /Count 1 >>"),
                (21, "<< /Title (One) /Parent 20 0 R /Dest [8 0 R /Fit] >>"),
                (24, "<< /Type /Annot /Subtype /Link /Rect [72 72 144 90] /Dest (sec1) >>"),
                (25, "<< /Type /Annot /Subtype /Link /Rect [72 100 144 120] /A << /S /GoTo /D [7 0 R /Fit] >> >>"),
                (26, "<< /Names [(sec1) [6 0 R /Fit]] >>"),
                (27, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 200 200 220] /P 5 0 R >>"),
                (28, "<< /Type /StructTreeRoot /K [] >>"),
            ])
        // Remove page B, which the named destination leads to, then copy.
        let trimmed = try apply([0, 2, 3].map { PageSlot(.original($0), rotation: [90, 90, 0, 0][$0]) }, to: original)
        let copy = [UInt8](try PDFSlimCopy.making(from: Data(trimmed)))
        let structure = try PDFStructure(copy)
        let pages = try structure.pageNumbers()
        XCTAssertEqual(pages.count, 3)
        let catalog = try structure.catalog()
        XCTAssertNil(catalog["StructTreeRoot"])
        let entry = try structure.resolve(structure.resolve(catalog["Outlines"]!)["First"]!)
        XCTAssertEqual(entry["Dest"]?.array?.first?.reference?.number, pages[2], "the outline leads to page D, now the third")
        let annots = try structure.object(pages[0])["Annots"]?.array ?? []
        XCTAssertEqual(annots.count, 3)
        let goTo = try structure.resolve(annots[1])
        XCTAssertEqual(try structure.resolve(goTo["A"]!)["D"]?.array?.first?.reference?.number, pages[1], "the link leads to page C, now the second")
        XCTAssertNil(try structure.resolve(annots[0])["Dest"], "the link to the removed page already led nowhere")
        let field = try structure.resolve(try structure.resolve(catalog["AcroForm"]!)["Fields"]!.array![0])
        XCTAssertEqual(field["P"]?.reference?.number, pages[0])
        XCTAssertEqual(annots[2].reference?.number, try structure.resolve(catalog["AcroForm"]!)["Fields"]!.array![0].reference?.number,
                       "the field and the page's widget are one object")
        XCTAssertNil(try structure.object(pages[0])["StructParents"])
        let after = try document(copy)
        XCTAssertEqual(texts(after), ["Page A", "Page C", "Page D"])
        XCTAssertEqual(after.outlineRoot?.child(at: 0)?.destination?.page.map { after.index(for: $0) }, 2)
    }

    func testASlimCopyLeavesAUsageRightsSealBehind() throws {
        var sealed = MiniPDF()
        sealed.catalogExtras = MiniPDF.usageRightsSeal
        let copy = [UInt8](try PDFSlimCopy.making(from: Data(sealed.classic())))
        let structure = try PDFStructure(copy)
        XCTAssertNil(try structure.refusalReason(), "the copy can still be annotated")
        XCTAssertNil(try structure.catalog()["Perms"])
        XCTAssertEqual(try structure.catalog()["AcroForm"]?["SigFlags"]?.int, 0, "the form no longer says signatures exist")
        XCTAssertEqual(occurrences(of: "/ByteRange", in: copy), 0)
    }

    func testAPageEditRetiresAUsageRightsSeal() throws {
        for (form, inline) in [(" /AcroForm 20 0 R", false), (" /AcroForm << /SigFlags 3 /Fields [] >>", true)] {
            var sealed = MiniPDF()
            sealed.catalogExtras = " /Perms << /UR3 << /Type /Sig /ByteRange [0 1 2 3] >> >>" + form
            if !inline { sealed.extraObjects = [(20, 0, "<< /SigFlags 3 /Fields [] >>")] }
            let original = sealed.classic()
            let turned = try apply(originalSlots(2, rotations: [0: 90]), to: original)
            let structure = try PDFStructure(turned)
            XCTAssertNil(try structure.catalog()["Perms"])
            XCTAssertEqual(try structure.resolve(structure.catalog()["AcroForm"]!)["SigFlags"]?.int, 0)
            XCTAssertNil(try structure.refusalReason(), "marks and page edits can still be saved")
            // And again on top: the seal stays retired.
            let again = try apply(originalSlots(2, rotations: [1: 90]), to: turned)
            XCTAssertNil(try PDFStructure(again).refusalReason())
            XCTAssertEqual(try document(again).page(at: 1)?.rotation, 90)
            _ = try PDFAppendWriter.appending([MarkupAddition(pageIndex: 0, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)],
                                                              red: 1, green: 1, blue: 0)], to: Data(again))
        }
    }

    func testASealKeptInACatalogInsideAnObjectPackIsRetiredToo() throws {
        // The seal's signature is an object of its own; the catalog naming it was saved inside a pack.
        var base = MiniPDF()
        base.extraObjects = [(20, 0, "<< /Type /Sig /ByteRange [0 1 2 3] /Contents <00> >>")]
        let sealed = MiniPDF.update(base.classic(), liveInCompressedPart: [
            (1, "<< /Type /Catalog /Pages 2 0 R /Perms << /UR3 20 0 R >> /AcroForm << /SigFlags 3 /Fields [] >> >>"),
        ])
        XCTAssertNil(try PDFStructure(sealed).refusalReason())
        let turned = try apply(originalSlots(2, rotations: [0: 90]), to: sealed)
        XCTAssertNil(try PDFStructure(turned).catalog()["Perms"])
        XCTAssertNil(try PDFStructure(turned).refusalReason())
        XCTAssertEqual(try document(turned).page(at: 0)?.rotation, 90)
    }

    func testARetiredSealDoesNotHideASignature() throws {
        var sealed = MiniPDF()
        sealed.catalogExtras = " /Perms << /UR3 << /Type /Sig /ByteRange [0 1 2 3] >> >> /AcroForm << /SigFlags 3 /Fields [] >>"
        let turned = try apply(originalSlots(2, rotations: [0: 90]), to: sealed.classic())
        // A later program signs the document: a signature record outside the old seal.
        let signed = MiniPDF.update(turned, objects: [(20, 0, "<< /Type /Sig /ByteRange [0 1 2 3] /Contents <00> >>")])
        XCTAssertEqual(try PDFStructure(signed).refusalReason(), "digitally signed")
        // A form that still says signatures exist, without a seal, is believed.
        let flagged = MiniPDF.update(turned, objects: [(1, 0, "<< /Type /Catalog /Pages 2 0 R /AcroForm << /SigFlags 1 /Fields [] >> >>")])
        XCTAssertEqual(try PDFStructure(flagged).refusalReason(), "digitally signed")
    }

    func testFilesThatAreNotCopied() {
        var locked = MiniPDF()
        locked.encrypted = true
        XCTAssertThrowsError(try PDFSlimCopy.making(from: Data(locked.classic()))) { error in
            XCTAssertEqual((error as? PDFAppendError)?.description, "refused: password-protected")
        }
    }

    // MARK: Found in review

    func testANullResourceIsTakenAsNotWritten() throws {
        // Page A writes /Resources null and takes its font from its branch, as readers read it.
        let original = twoBranchPDF(pageExtras: [0: " /Resources null /MediaBox null"])
        XCTAssertEqual(texts(try document(original))[0], "Page A")
        let moved = try apply([1, 0, 2, 3].map { PageSlot(.original($0), rotation: [90, 90, 0, 0][$0]) }, to: original)
        let after = try document(moved)
        XCTAssertEqual(texts(after), ["Page B", "Page A", "Page C", "Page D"])
        XCTAssertEqual(after.page(at: 1)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 400, height: 600))
        let inserted = try apply(originalSlots(2) + [PageSlot(.inserted(source: 0, page: 0), rotation: 90)], to: MiniPDF().classic(), sources: [original])
        XCTAssertEqual(texts(try document(inserted)).last, "Page A")
        XCTAssertEqual(texts(try document([UInt8](try PDFSlimCopy.making(from: Data(original)))))[0], "Page A")
    }

    func testABranchThatNamesAnotherParentThanTheOneListingItIsNotEdited() {
        // Branch 3 is listed by the root but names branch 4 as its parent.
        let original = twoBranchPDF().replacingParent(of: 3, with: 4)
        XCTAssertNoThrow(try PDFStructure(original).pageNumbers(), "the file itself is sound")
        assertRefused([1, 0, 2, 3].map { PageSlot(.original($0), rotation: [90, 90, 0, 0][$0]) }, original, because: "another branch")
        XCTAssertNotNil(PDFPageWriter.reasonPagesCannotBeInserted(from: Data(original)))
        XCTAssertThrowsError(try PDFSlimCopy.making(from: Data(original)))
    }

    func testARootThatNamesAParentIsNotEdited() {
        // The root (2) names branch 4 as its parent; one digit, so the index stays right.
        let text = String(decoding: twoBranchPDF(), as: UTF8.self)
        let original = Array(text.replacingOccurrences(of: "2 0 obj\n<< /Type /Pages /Kids", with: "2 0 obj\n<</Parent 4 0 R /Kids").utf8)
        XCTAssertEqual(original.count, twoBranchPDF().count)
        XCTAssertNoThrow(try PDFStructure(original).pageNumbers(), "the file itself is sound")
        assertRefused([1, 0, 2, 3].map { PageSlot(.original($0), rotation: [90, 90, 0, 0][$0]) }, original, because: "another branch")
        XCTAssertNotNil(PDFPageWriter.reasonPagesCannotBeInserted(from: Data(original)))
        XCTAssertThrowsError(try PDFSlimCopy.making(from: Data(original)))
    }

    func testAPageThatNamesAnotherBranchThanTheOneListingItIsNotEdited() {
        // Page C is listed by branch 4 but names the root as its parent.
        let original = twoBranchPDF(parentOverride: [2: 2])
        assertRefused(originalSlots(4, rotations: [0: 90, 1: 90, 2: 90]), original, because: "another branch")
        assertRefused([3, 2, 1, 0].map { PageSlot(.original($0), rotation: [90, 90, 0, 0][$0]) }, original, because: "another branch")
        XCTAssertNotNil(PDFPageWriter.reasonPagesCannotBeInserted(from: Data(original)))
        assertRefused(originalSlots(2) + [PageSlot(.inserted(source: 0, page: 0), rotation: 0)], MiniPDF().classic(),
                      sources: [original], because: "another branch")
        XCTAssertThrowsError(try PDFSlimCopy.making(from: Data(original)))
    }
}
