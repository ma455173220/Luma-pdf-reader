import PDFKit
import XCTest
@testable import LumaCore

/// Outlines worked out from a paper's text: headings found by their type, numbering and names, and
/// what looks like a heading but is not one.
final class OutlineDecodingTests: XCTestCase {
    /// A run of text: what it says, its size, and its font (0 regular, 1 bold, 2 italic).
    private typealias Run = (text: String, size: Double, font: Int)

    /// A paper whose runs are set in Times, in regular, bold or italic. Lines are 14 points apart.
    private func paper(_ pages: [[Run]]) -> PDFDocument {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Bold >>",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Italic >>"]
        var kids: [Int] = []
        for lines in pages {
            var stream = "BT 14 TL 72 740 Td\n"
            for run in lines {
                let escaped = run.text.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
                stream += "/F\(run.font + 1) \(run.size) Tf (\(escaped)) Tj T*\n"
            }
            stream += "ET"
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
            let contents = objects.count
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contents) 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> >>")
            kids.append(objects.count)
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>"
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let start = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return PDFDocument(data: Data(out.utf8))!
    }

    private func text(_ count: Int = 3) -> [Run] {
        Array(repeating: ("Plain running text of the paper, which goes on for quite a while here.", 10, 0), count: count)
    }
    private func heading(_ title: String, size: Double = 12, font: Int = 1) -> Run { (title, size, font) }

    // MARK: Fonts

    func testTheFontOfEachPieceOfTextIsReadFromThePage() throws {
        let document = paper([[heading("1. Introduction")] + text(1)])
        let runs = PageFonts.runs(of: try XCTUnwrap(document.page(at: 0)))
        XCTAssertEqual(runs.map(\.font), ["Times-Bold", "Times-Roman"])
        XCTAssertEqual(runs[0].size, 12, accuracy: 0.01)
        XCTAssertEqual(runs[0].origin.y, 740, accuracy: 0.01)
        XCTAssertEqual(runs[1].origin.y, 726, accuracy: 0.01)
    }

    /// A one-page file from the objects given, numbered from 1; object 3 must be the page.
    private func onePage(_ objects: [String]) -> PDFDocument {
        let all = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"] + objects
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, body) in all.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let start = out.utf8.count
        out += "xref\n0 \(all.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(all.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return PDFDocument(data: Data(out.utf8))!
    }

    private func stream(_ content: String, _ extra: String = "") -> String {
        "<< /Length \(content.utf8.count)\(extra) >>\nstream\n\(content)\nendstream"
    }

    func testRestoringTheGraphicsStateRestoresTheFont() throws {
        let fonts = "/Font << /F1 5 0 R /F2 6 0 R >>"
        let document = onePage(["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << \(fonts) >> >>",
                                stream("/F2 12 Tf q /F1 10 Tf Q BT 72 700 Td (After) Tj ET"),
                                "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>",
                                "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Bold >>"])
        let runs = PageFonts.runs(of: try XCTUnwrap(document.page(at: 0)))
        XCTAssertEqual(runs.map(\.font), ["Times-Bold"])
        XCTAssertEqual(runs.first?.size ?? 0, 12, accuracy: 0.01)
    }

    func testAFormDrawnInsideItselfIsReadOnce() throws {
        // The form draws itself before its text: followed without a check, it would never end.
        let resources = "/Resources << /XObject << /X1 4 0 R >> /Font << /F1 5 0 R >> >>"
        let document = onePage(["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R \(resources) >>",
                                stream("/X1 Do BT /F1 10 Tf 72 700 Td (Inside) Tj ET", " /Type /XObject /Subtype /Form /BBox [0 0 612 792] \(resources)"),
                                "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>",
                                stream("/X1 Do")])
        let started = Date()
        let runs = PageFonts.runs(of: try XCTUnwrap(document.page(at: 0)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(runs.map(\.font), ["Times-Roman"])
    }

    func testFontNamesThatMeanBoldOrItalic() {
        XCTAssertTrue(PageFonts.isBold("Helvetica-Bold"))
        XCTAssertTrue(PageFonts.isBold("CMBX10"), "TeX's bold")
        XCTAssertTrue(PageFonts.isBold("AdvOTaa6301a5.B"))
        XCTAssertTrue(PageFonts.isItalic("CMTI9"))
        XCTAssertTrue(PageFonts.isItalic("ScalaSansPro-Italic"))
        XCTAssertFalse(PageFonts.isBold("Times-Roman"))
        XCTAssertFalse(PageFonts.isItalic("MinionPro-Regular"))
    }

    // MARK: Headings

    func testNumberedHeadingsTakeTheirLevelFromTheirNumbers() {
        let document = paper([
            [heading("A Study of Clusters", size: 18)] + text() + [heading("1. Introduction")] + text() + [heading("2. Methods")] + text(),
            [heading("2.1. The model", size: 10)] + text() + [heading("2.1.1. Its parameters", size: 10, font: 2)] + text()
                + [heading("3. Results and Discussion")] + text() + [heading("References")]
                + [("1. A. Author, Clusters of Things, J. Test, 2020.", 9, 2), ("2. B. Writer, More Clusters, J. Test, 2021.", 9, 2)],
        ])
        let found = OutlineDecoder.headings(of: document)
        XCTAssertEqual(found.map(\.title), ["1. Introduction", "2. Methods", "2.1. The model", "2.1.1. Its parameters", "3. Results and Discussion", "References"],
                       "the title and the reference list are left out")
        XCTAssertEqual(found.map(\.depth), [0, 0, 1, 2, 0, 0])
        XCTAssertEqual(found.map(\.page), [0, 0, 1, 1, 1, 1])
        let entries = OutlineDecoder.entries(of: document)
        XCTAssertEqual(entries.map(\.hasChildren), [false, true, true, false, false, false])
    }

    func testUnnumberedHeadingsAreThoseRunningTextFollows() {
        let document = paper([
            [heading("Introduction")] + text() + [heading("Results and discussion")] + [heading("Comparison of the two models", size: 10)] + text()
                + [heading("Energy (eV)", size: 10), heading("Time (min)", size: 10)],
            [heading("Behaviour under strain", size: 10)] + text() + [heading("Conclusions")] + text(),
        ])
        let found = OutlineDecoder.headings(of: document)
        XCTAssertEqual(found.map(\.title), ["Introduction", "Results and discussion", "Comparison of the two models", "Behaviour under strain", "Conclusions"],
                       "the labels of a figure are no headings")
        XCTAssertEqual(found.map(\.depth), [0, 0, 1, 1, 0])
    }

    func testRunningHeadsAndTablesOfContentsAreNoHeadings() {
        let head: Run = ("J. Test. 2024, 12, 345", 10, 1)
        let pages: [[Run]] = [
            [head, heading("Contents"), ("1 Introduction 2", 10, 1), ("2 Methods 3", 10, 1)] + text(),
            [head, heading("1 Introduction")] + text() + [heading("2 Methods")] + text(),
            [head] + text(4) + [heading("3 Conclusions")] + text(),
            [head] + text(4) + [heading("Acknowledgements")] + text(),
        ]
        let found = OutlineDecoder.headings(of: paper(pages))
        XCTAssertEqual(found.map(\.title), ["1 Introduction", "2 Methods", "3 Conclusions", "Acknowledgements"])
        XCTAssertEqual(found.map(\.page), [1, 1, 2, 3])
    }

    func testWhatLooksLikeAHeadingButIsNone() {
        let document = paper([
            [heading("1. Introduction")] + text(),
            // A figure's legend in bold: section names with no text after them.
            [heading("Theory", size: 10), heading("Experimental", size: 10), ("0.5 1.0 1.5", 8, 0)] + text(),
            [heading("2. Methods")] + text()
                // A reference and an address that happen to be set in bold and numbered.
                + [heading("3. A. Author, B. Writer et al., J. Phys. Chem. 2020, 12, 345.", size: 10)] + text()
                + [heading("4. Department of Physics, University of Somewhere", size: 10)] + text()
                // A heading the paragraph runs on from, and a row of a table.
                + [heading("2.1. The model and its parameters. When new", size: 10)] + text()
                + [heading("Sample 122 ± 8 3.5", size: 10)] + text(),
            [heading("3. Results")] + text() + [heading("References")] + text(),
        ])
        let found = OutlineDecoder.headings(of: document)
        XCTAssertEqual(found.map(\.title), ["1. Introduction", "2. Methods", "3. Results", "References"])
    }

    func testAHeadingOverTwoLinesStaysOneEvenWhenItsSecondLineIsASectionName() {
        let document = paper([
            [heading("1. Introduction")] + text(),
            [heading("2. Density Functional"), heading("Theory")] + text() + [heading("3. Conclusions")] + text(),
        ])
        XCTAssertEqual(OutlineDecoder.headings(of: document).map(\.title), ["1. Introduction", "2. Density Functional Theory", "3. Conclusions"])
    }

    func testRomanNumeralsLettersAndNumbersFollowOnOrAreLeftOut() {
        let document = paper([
            [heading("I. INTRODUCTION", size: 10)] + text() + [heading("II. METHODS", size: 10)] + text()
                + [heading("A. The model", size: 10)] + text() + [heading("1. Its parameters", size: 10)] + text(),
            [heading("F. C. Chou, B. Writer and C. Author", size: 10)] + text()          // initials, not a section
                + [heading("D. Out of order", size: 10)] + text()                          // A., then D.: no
                + [heading("B. The method", size: 10)] + text()
                + [heading("III. RESULTS", size: 10)] + text() + [heading("ACKNOWLEDGMENTS", size: 10)] + text(),
        ])
        let found = OutlineDecoder.headings(of: document)
        XCTAssertEqual(found.map(\.title), ["I. INTRODUCTION", "II. METHODS", "A. The model", "1. Its parameters", "B. The method", "III. RESULTS", "ACKNOWLEDGMENTS"],
                       "initials are no section; after A., D. is out of order and B. follows on")
        XCTAssertEqual(found.map(\.depth), [0, 0, 1, 2, 1, 0, 0])
    }

    func testATableOfContentsWithoutPageNumbersIsNoOutline() {
        let document = paper([
            [heading("Contents"), ("1 Introduction", 9, 1), ("2 Methods", 9, 1), ("3 Results", 9, 1)] + text(),
            [heading("1 Introduction")] + text() + [heading("2 Methods")] + text(),
            [heading("3 Results")] + text(),
        ])
        let found = OutlineDecoder.headings(of: document)
        XCTAssertEqual(found.map(\.title), ["1 Introduction", "2 Methods", "3 Results"])
        XCTAssertEqual(found.map(\.page), [1, 1, 2], "the headings in the text, not the entries of the contents")
    }

    func testTooLittleToGoOnGivesNoOutline() {
        XCTAssertTrue(OutlineDecoder.headings(of: paper([[heading("Something in bold")] + text(5)])).isEmpty)
        XCTAssertTrue(OutlineDecoder.headings(of: paper([text(5)])).isEmpty)
    }

    // MARK: Passing an outline between processes

    func testAnOutlineReadBackIsTheOneWrittenOut() {
        let entries = [OutlineEntry(title: "1. Introduction", depth: 0, page: 0, point: CGPoint(x: 72, y: 700), hasChildren: true),
                       OutlineEntry(title: "1.1 Background", depth: 1, page: 1, point: nil, hasChildren: false)]
        XCTAssertEqual(DocumentOutline.decoded(DocumentOutline.encoded(entries), pageCount: 2), entries)
        let beyond = DocumentOutline.decoded(DocumentOutline.encoded(entries), pageCount: 1)
        XCTAssertEqual(beyond?.last?.page, nil, "a page the document does not have leads nowhere")
        XCTAssertNil(DocumentOutline.decoded(Data("not an outline".utf8), pageCount: 2))
    }
}
