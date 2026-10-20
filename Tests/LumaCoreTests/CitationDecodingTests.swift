import PDFKit
import XCTest
@testable import LumaCore

/// Citations read from a paper's text: the reference list, the forms citations take, and what is not
/// a citation although it looks like one.
final class CitationDecodingTests: XCTestCase {
    private typealias Run = TextPaper.Run
    private func paper(_ pages: [[[Run]]]) -> Data { TextPaper.data(pages) }

    private func body(_ text: String) -> [Run] { [(text, 10, 0)] }
    private func raised(_ text: String) -> Run { (text, 6, 4) }

    /// Three pages of text and a reference list of six entries on the last.
    private func samplePaper(firstPage: [[Run]] = [], citing: [[Run]]) -> PDFDocument {
        let filler = (0..<10).map { _ in body("Plain running text of the paper, which goes on for a while here.") }
        let references: [[Run]] = [body("References")] + (1...6).map { body("\($0) A. Author\($0), B. Writer, J. Phys. Chem. 20\(10 + $0), \($0)2, 1\($0)3.") }
        let data = paper([firstPage + filler, citing + filler, references])
        return PDFDocument(data: data)!
    }

    // MARK: The reference list

    func testTheListIsFoundUnderItsHeadingWithEveryEntryInPlace() throws {
        let document = samplePaper(citing: [body("Nothing cited here.")])
        let list = try XCTUnwrap(ReferenceList.find(in: document))
        XCTAssertEqual(list.count, 6)
        XCTAssertEqual(list.style, .plain)
        XCTAssertEqual(list.startPage, 2)
        let page = try XCTUnwrap(document.page(at: 2))
        for n in 1...6 {
            let entry = try XCTUnwrap(list.entries[n])
            XCTAssertEqual(entry.page, 2)
            // The label's place is where that entry's line starts.
            XCTAssertEqual(page.selection(for: entry.labelRect.insetBy(dx: -0.5, dy: -0.5))?.string?.trimmingCharacters(in: .whitespaces).prefix(1), "\(n)".prefix(1))
        }
        XCTAssertGreaterThan(list.entries[1]!.point.y, list.entries[2]!.point.y, "in order down the page")
    }

    func testAListWithoutAHeadingStartsAtTheFirstEntryWithAnAuthor() throws {
        // A numbered point of the text ("1 In the presence…") is not the start of the list.
        let points: [[Run]] = (1...3).map { body("\($0) In the presence of vacancies, levels appear.") }
        let entries: [[Run]] = (1...4).map { body("\($0) M. Fujimoto and W. D. Kingery, J. Am. Ceram. Soc. 68, 169 (1985).") }
        let document = PDFDocument(data: paper([[body("Introduction")], [body("Text.")], points, entries]))!
        let list = try XCTUnwrap(ReferenceList.find(in: document))
        XCTAssertEqual(list.startPage, 3)
        XCTAssertEqual(list.count, 4)
    }

    func testLabelsThatCameOutAsAColumnStillFindTheirEntries() throws {
        // "[1] [2] [3] Dresselhaus…": the labels form their own column.
        let lines: [[Run]] = [body("References"), body("[1] [2] [3] Dresselhaus, M. S. Alternative energy. Nature 2001."),
                              body("Turner, J. A. Sustainable hydrogen. Science 2004."), body("Paracchino, A. Oxide photocathode. Nat. Mater. 2011."),
                              body("[4] Ursua, A. Hydrogen production. Proc. IEEE 2012.")]
        let document = PDFDocument(data: paper([[body("Intro.")], [body("Text.")], lines]))!
        let list = try XCTUnwrap(ReferenceList.find(in: document))
        XCTAssertEqual(list.entries.keys.sorted(), [1, 2, 3, 4])
        XCTAssertEqual(list.style, .brackets)
    }

    // MARK: Citations

    func testCitationsInBracketsRaisedAndWrittenOutAreFound() throws {
        let document = samplePaper(citing: [
            [("Copper is a catalyst for fuels.", 10, 0), raised("1,2"), (" It was studied", 10, 0), raised("3-5"), (" and more.", 10, 0)],
            body("A review [6] and another [2, 4] say so; see ref. 3 for details."),
        ])
        let decoder = CitationDecoder(document: document)
        let markers = decoder.markers(onPage: 1)
        let text = try XCTUnwrap(document.page(at: 1)?.string as NSString?)
        let found = markers.map { (text.substring(with: $0.range).replacingOccurrences(of: "\n", with: ""), $0.numbers) }
        XCTAssertTrue(found.contains { $0.1 == [1, 2] }, "\(found)")
        XCTAssertTrue(found.contains { $0.1 == [3, 4, 5] }, "\(found)")
        XCTAssertTrue(found.contains { $0.0 == "[6]" && $0.1 == [6] }, "\(found)")
        XCTAssertTrue(found.contains { $0.1 == [2, 4] }, "\(found)")
        XCTAssertTrue(found.contains { $0.0.hasPrefix("ref.") && $0.1 == [3] }, "\(found)")
    }

    func testEachNumberLeadsToItsOwnEntry() throws {
        let document = samplePaper(citing: [[("Two studies agree.", 10, 0), raised("2,5"), (" Yes.", 10, 0)]])
        let decoder = CitationDecoder(document: document)
        let list = try XCTUnwrap(decoder.referenceList)
        let links = decoder.links(onPage: 1)
        XCTAssertEqual(links.count, 2)
        let targets = links.compactMap { link -> CGPoint? in if case .place(_, let point) = link.target { return point } else { return nil } }
        XCTAssertEqual(targets, [list.entries[2]!.point, list.entries[5]!.point])
        XCTAssertLessThan(links[0].rect.minX, links[1].rect.minX)
    }

    func testRaisedNumbersThatAreNotCitationsAreLeftAlone() throws {
        let document = samplePaper(
            firstPage: [[("Tomohito Tanaka,", 10, 0), raised("1"), (" Katsuyuki Matsunaga", 10, 0), raised("2")]],
            citing: [
                [("A density of 10 mA cm", 10, 0), raised("2"), (" was reached.", 10, 0)],          // a unit squared, sign lost
                [("The sample measured 3 cm", 10, 0), raised("3"), (" across.", 10, 0)],            // cubed, touching
                [("An energy of 1.3 10", 10, 0), raised("4"), (" J was found.", 10, 0)],           // a power of ten
                [("Ions of Fe", 10, 0), raised("3"), ("+ were found.", 10, 0)],                    // a charge
                [("The isotope ", 10, 0), raised("5"), ("N was used.", 10, 0)],                    // an isotope, and a space
                [("The area grows as x", 10, 0), raised("2"), (" here.", 10, 0)],                  // a variable squared
            ])
        let decoder = CitationDecoder(document: document)
        XCTAssertTrue(decoder.markers(onPage: 0).isEmpty, "affiliation marks: \(decoder.markers(onPage: 0).map(\.numbers))")
        XCTAssertTrue(decoder.markers(onPage: 1).isEmpty, "\(decoder.markers(onPage: 1).map(\.numbers))")
    }

    func testACitationNamingAnEntryTheListDoesNotHaveIsLeftAlone() {
        let document = samplePaper(citing: [body("Beyond the list [7] and partly [5–8] beyond it.")])
        XCTAssertTrue(CitationDecoder(document: document).markers(onPage: 1).isEmpty)
    }

    func testNumbersInBracketsThatAreNotCitations() {
        XCTAssertNil(CitationMarkers.numbers(in: "011"), "a crystal direction with a leading zero")
        XCTAssertNil(CitationMarkers.numbers(in: "−110"), "a crystal direction with a sign")
        XCTAssertNil(CitationMarkers.numbers(in: "9–3"), "a range that runs backward")
        XCTAssertEqual(CitationMarkers.numbers(in: "21b,c,29"), [21, 29])
        XCTAssertEqual(CitationMarkers.numbers(in: "14−16"), [14, 15, 16])
    }

    // MARK: Preparing in the background

    func testADocumentThatLinksItsOwnCitationsIsLeftToItsLinks() throws {
        var file = MiniPDF()
        file.extraObjects = (0..<3).map { (20 + $0, 0, "<< /Type /Annot /Subtype /Link /Rect [72 \(600 + 20 * $0) 90 \(612 + 20 * $0)] /Dest [4 0 R /XYZ 72 700 0] >>") }
        file.pageExtras = " /Annots [20 0 R 21 0 R 22 0 R]"
        file.annotations = .none
        let document = try XCTUnwrap(PDFDocument(data: Data(file.classic())))
        XCTAssertTrue(CitationDecoder.carriesCitationLinks(document))
        XCTAssertFalse(CitationDecoder.carriesCitationLinks(samplePaper(citing: [body("No links.")])))
    }

    func testPreparationFromTheFileGivesTheSameLinks() throws {
        let data = paper([[body("Intro.")], [[("Cited here.", 10, 0), raised("4"), (" More.", 10, 0)]],
                          [body("References")] + (1...6).map { body("\($0) A. Author, J. Phys. 20\(10 + $0).") }])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("citations-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let preparation = try XCTUnwrap(CitationDecoder.prepare(fileAt: url))
        XCTAssertTrue(CitationDecoder.fits(preparation, document))
        let prepared = CitationDecoder(document: document, preparation: preparation)
        XCTAssertEqual(prepared.links(onPage: 1), CitationDecoder(document: document).links(onPage: 1))
    }
}
