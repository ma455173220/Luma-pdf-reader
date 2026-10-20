import AppKit
import PDFKit
import XCTest
@testable import LumaCore

/// References to figures and tables read from a paper's text, the captions they lead to, and where
/// the preview of a figure starts.
final class FigureDecodingTests: XCTestCase {
    private typealias Run = TextPaper.Run
    private func body(_ text: String) -> [Run] { [(text, 10, 0)] }
    private func caption(_ text: String) -> [Run] { [(text, 7, 0)] }
    private let blank: [Run] = []
    private let filler = "Plain running text of the paper, which goes on for a while here."

    private func document(_ pages: [[[Run]]]) -> PDFDocument { PDFDocument(data: TextPaper.data(pages))! }

    /// Where each link on a page leads: the page, by the order of the links.
    private func targets(_ links: [PageLink]) -> [Int] {
        links.compactMap { if case .place(let page, _) = $0.target { return page } else { return nil } }
    }

    /// Text in a type size, for reading labels without a file.
    private func text(_ string: String, size: CGFloat = 10) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size)])
    }

    // MARK: Reading the labels

    func testTheWaysAReferenceIsWritten() {
        let labels = FigureReferences.labels(in: text("as in Fig. 2 and Figures 1a and 3(b), Table II, Tab. 4, Scheme 1 and 图 5、6."))
        XCTAssertEqual(labels.map(\.kind), [.figure, .figure, .table, .table, .scheme, .figure])
        XCTAssertEqual(labels.map { $0.numbers.compactMap(\.number) }, [[2], [1, 3], [2], [4], [1], [5, 6]])
        XCTAssertTrue(labels[5].chinese)
    }

    func testWhatIsNotAReferenceToAFigureOfThisFile() {
        let labels = FigureReferences.labels(in: text("see Fig. S3, Supplementary Fig. 2, Supplemen-\ntary Table 4, Figure 2.1, 代表 3 种 and showninFig.6."))
        // Supplementary material is outside the file; a number within a chapter is not the figure's own.
        XCTAssertEqual(labels.map { $0.numbers.compactMap(\.number) }, [[], [2], [4], [6]])
        XCTAssertEqual(labels.map(\.supplementary), [false, true, true, false], "the word may be broken over a line")
    }

    func testAFullStopBeforeARaisedCitationIsNotAChapterNumber() {
        let written = NSMutableAttributedString(attributedString: text("as in Fig. 4."))
        written.append(text("92", size: 6))
        XCTAssertEqual(FigureReferences.labels(in: written).first?.numbers.compactMap(\.number), [4])
    }

    func testANumberTheSentenceGoesOnFromIsNoFigure() {
        let labels = FigureReferences.labels(in: text("As shown in Fig. 3, 2D materials grow. In Fig. 4, 3 regimes appear. Figure 3, 14a is a cage. Figs. 5, 7, 9 agree, and so do Fig. 1, 2 and 6."))
        XCTAssertEqual(labels.map { $0.numbers.compactMap(\.number) }, [[3], [4], [3], [5, 7, 9], [1, 2, 6]])
    }

    func testReferencesToOtherWorksAndSupplementaryMaterialAreLeftAlone() {
        let written = "Fig. 3 of ref. 12, Table 2 in [7], (Table 2 of Ref. [1]), Table 3 in the Supporting Information, Supplementary Information Fig. 2, Supplementary Material Table 1, 附表 1, 附图 1, 补充材料图 1, and Fig. 1(d)) of 1S-MoSSe."
        let labels = FigureReferences.labels(in: text(written))
        XCTAssertEqual(labels.map(\.supplementary), [true, true, true, true, true, true, true, false], "\(labels.map { $0.numbers.compactMap(\.number) })")
        XCTAssertEqual(labels.last?.numbers.compactMap(\.number), [1], "a figure of this paper, followed by words of its own")
    }

    // MARK: Captions and links

    func testReferencesLeadToTheirCaptions() throws {
        let doc = document([
            [body("The model, as shown in Fig. 2 and Table 1, and in Figures 1a and 2(b).")] + (0..<6).map { _ in body(filler) },
            (0..<4).map { _ in body(filler) } + [blank, blank, blank, caption("Fig. 1. The relaxed structure of the model."),
             blank, blank, blank, caption("Fig. 2 Band structure of the model."), caption("Table 1. Energies of the model.")],
        ])
        let decoder = FigureDecoder(document: doc)
        let mentions = decoder.mentions(onPage: 0)
        XCTAssertEqual(mentions.flatMap { $0.parts.map(\.number) }, [2, 1, 1, 2])
        XCTAssertTrue(decoder.mentions(onPage: 1).isEmpty, "a caption is not a reference")
        let links = decoder.links(onPage: 0)
        XCTAssertEqual(targets(links), [1, 1, 1, 1])
        let table = try XCTUnwrap(decoder.caption(of: .table, 1, near: 0))
        let start = try XCTUnwrap(decoder.target(of: table))
        let line = try XCTUnwrap(doc.page(at: 1)?.selection(for: table.range)?.bounds(for: doc.page(at: 1)!))
        XCTAssertEqual(start.page, 1)
        XCTAssertEqual(start.point.y, line.maxY, accuracy: 3, "a table's preview starts at its caption")
    }

    func testADecoderReadingADocumentOfItsOwnLetsGoOfItAndOpensItAgain() throws {
        let doc = document([
            [body("The model, as shown in Fig. 2 and Table 1, and in Figures 1a and 2(b).")] + (0..<6).map { _ in body(filler) },
            (0..<4).map { _ in body(filler) } + [blank, blank, blank, caption("Fig. 1. The relaxed structure of the model."),
             blank, blank, blank, caption("Fig. 2 Band structure of the model."), caption("Table 1. Energies of the model.")],
        ])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        XCTAssertTrue(doc.write(to: file))
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = TextReader(file: file, pageCount: doc.pageCount)
        let decoder = FigureDecoder(reading: reader, pageCount: doc.pageCount, bodySize: nil)
        XCTAssertFalse(reader.isHolding, "nothing opened until asked")
        let pending = decoder.pendingLinks(onPage: 0)
        XCTAssertTrue(reader.isHolding)
        reader.letGo()
        XCTAssertFalse(reader.isHolding)
        XCTAssertEqual(targets(pending.compactMap { decoder.resolved($0, onPage: 0) }), [1, 1, 1, 1], "opened again to find the captions")
        XCTAssertEqual(targets(decoder.links(onPage: 0)), targets(FigureDecoder(document: doc).links(onPage: 0)))
        let otherReader = TextReader(file: file, pageCount: doc.pageCount + 1)
        let other = FigureDecoder(reading: otherReader, pageCount: doc.pageCount + 1, bodySize: nil)
        XCTAssertTrue(other.pendingLinks(onPage: 0).isEmpty, "a file that no longer matches the document shown is not read")
    }

    func testAReferenceEndingASentenceAtTheStartOfALineIsNotACaption() {
        // "…are listed in⏎Table 3. For all…" in the text's own type, right under the line before.
        let doc = document([
            [body("The distances from each vacancy are listed in"), body("Table 3. For all vacancy species the ions relax."), body(filler)],
            [caption("TABLE 3. Distances from a vacancy to its neighbours."), body(filler)],
        ])
        XCTAssertEqual(targets(FigureDecoder(document: doc).links(onPage: 0)), [1])
    }

    func testAReferenceInsideAnotherCaptionIsNoCaption() {
        // "Same as⏎Fig. 3 but for…" at the start of a line of figure 4's caption, in caption type.
        let doc = document([
            [caption("Fig. 3. The model at rest."), body(filler)],
            [body("As Fig. 3 shows, the model holds."), body(filler), caption("Fig. 4. The model under strain. Same as"), caption("Fig. 3 but for a strained model.")],
        ])
        // Both the text's reference and the one inside the caption lead to figure 3, on the page before.
        XCTAssertEqual(targets(FigureDecoder(document: doc).links(onPage: 1)), [0, 0])
    }

    func testASentenceAfterAReferenceAtTheTopOfAPageIsNoCaption() {
        // "Table 3. For all…" heading a page, in the text's own type: the next sentence of the text.
        let doc = document([
            [body("The distances are listed in"), body(filler)],
            [body("Table 3. For all vacancy species the ions relax."), body(filler)],
            [body(filler), body("Table 3. Distances from a vacancy to its neighbours."), body(filler)],
        ])
        XCTAssertEqual(targets(FigureDecoder(document: doc).links(onPage: 1)), [2])
    }

    func testTwoCaptionsThatCannotBeToldApartGiveNoLink() {
        let doc = document([
            [body("As Fig. 1 shows, the model holds."), body(filler)],
            [caption("Fig. 1. A first picture of the model."), body(filler), caption("Fig. 1. Another picture of the model.")],
        ])
        XCTAssertTrue(FigureDecoder(document: doc).links(onPage: 0).isEmpty)
    }

    func testATableContinuedOverAPageLeadsToWhereItStarts() {
        let doc = document([
            [caption("Table 1. Summary of the catalysts."), body(filler)],
            [caption("TABLE 1 (CONTINUED)"), body(filler)],
            [caption("Table 1 (cont'd)"), body(filler)],
            [body("The values in Table 1 agree."), body(filler)],
        ])
        XCTAssertEqual(targets(FigureDecoder(document: doc).links(onPage: 3)), [0])
    }

    func testACaptionMoreThanFivePagesAwayIsNotSought() {
        let pages: [[[Run]]] = [[caption("Fig. 1. The model."), body(filler)]] + (1...6).map { _ in [body(filler)] }
            + [[body("Recall Fig. 1 here."), body(filler)]]
        XCTAssertTrue(FigureDecoder(document: document(pages)).links(onPage: 7).isEmpty)
        let near: [[[Run]]] = [[caption("Fig. 1. The model."), body(filler)]] + (1...4).map { _ in [body(filler)] }
            + [[body("Recall Fig. 1 here."), body(filler)]]
        XCTAssertEqual(targets(FigureDecoder(document: document(near)).links(onPage: 5)), [0])
    }

    func testADashGivenAsTheLetterE() {
        let doc = document([[body("The studies are gathered in Table 2 below."), body(filler)],
                            [caption("Table 2e Synthesis of the principal studies."), body(filler)]])
        XCTAssertEqual(targets(FigureDecoder(document: doc).links(onPage: 0)), [1])
    }

    // MARK: Where a figure's preview starts

    func testAFigurePreviewStartsUnderTheTextAboveIt() throws {
        let lines = (0..<6).map { _ in body(filler) } + Array(repeating: blank, count: 12)
            + [caption("Fig. 1. The relaxed structure of the model in its ground state.")]
        let doc = document([[body("See Fig. 1."), body(filler)], lines])
        let decoder = FigureDecoder(document: doc)
        let figure = try XCTUnwrap(decoder.caption(of: .figure, 1, near: 0))
        let start = try XCTUnwrap(decoder.target(of: figure))
        let page = try XCTUnwrap(doc.page(at: 1))
        let lastText = try XCTUnwrap(page.selection(for: NSRange(location: 5 * (filler.count + 1), length: filler.count))?.bounds(for: page))
        let captionLine = try XCTUnwrap(page.selection(for: figure.range)?.bounds(for: page))
        XCTAssertEqual(start.page, 1)
        XCTAssertEqual(start.point.y, lastText.minY, accuracy: 3, "just under the last line of text")
        XCTAssertGreaterThan(start.point.y, captionLine.maxY + 100, "the whole figure is in view")
    }

    func testAFigureWithItsCaptionAtTheHeadOfTheNextPageStartsOnThePageBefore() throws {
        let doc = document([[body("See Fig. 1."), body(filler)], [blank], [caption("Fig. 1. A figure that fills the page before."), body(filler)]])
        let decoder = FigureDecoder(document: doc)
        let figure = try XCTUnwrap(decoder.caption(of: .figure, 1, near: 0))
        XCTAssertEqual(figure.page, 2)
        let start = try XCTUnwrap(decoder.target(of: figure))
        XCTAssertEqual(start.page, 1)
        XCTAssertEqual(start.point.y, 792, accuracy: 1, "from the top of that page")
    }
}
