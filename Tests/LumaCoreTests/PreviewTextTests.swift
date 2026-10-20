import PDFKit
import XCTest
@testable import LumaCore

/// What a preview marks: the reference-list entry a link leads to, or a figure's caption.
final class PreviewTextTests: XCTestCase {
    private typealias Run = TextPaper.Run
    private func line(_ text: String, size: Double = 10) -> [Run] { [(text, size, 0)] }

    private func lines(_ page: [[Run]]) throws -> [PreviewText.Line] {
        let document = try XCTUnwrap(PDFDocument(data: TextPaper.data([page])))
        return PreviewText.lines(of: try XCTUnwrap(document.page(at: 0)))
    }

    /// The top of the n-th line of a TextPaper page (counted from 0).
    private func top(ofLine n: Int) -> CGFloat { 740 + 10 - CGFloat(n) * 14 }

    func testTheEntryALinkLeadsToRunsToTheNextOne() throws {
        let page = try lines([
            line("References"),
            line("[1] A. Smith and B. Jones, Band structure of a model,"),
            line("Phys. Rev. B 12, 345 (2019)."),
            line("[2] C. Wu, Another paper, Nature 5, 6 (2020)."),
        ])
        let entry = PreviewText.entry(in: page, at: CGPoint(x: 72, y: top(ofLine: 1)))
        XCTAssertEqual(entry.map(\.text), ["[1] A. Smith and B. Jones, Band structure of a model,", "Phys. Rev. B 12, 345 (2019)."])
        XCTAssertTrue(PreviewText.looksLikeReference(entry))
        XCTAssertEqual(PreviewText.withoutNumber("[1] A. Smith, Phys. Rev. B 12, 345 (2019)."), "A. Smith, Phys. Rev. B 12, 345 (2019).")
        XCTAssertEqual(PreviewText.entry(in: page, at: CGPoint(x: 72, y: top(ofLine: 3))).map(\.text), ["[2] C. Wu, Another paper, Nature 5, 6 (2020)."])
    }

    func testAnEntryIsFoundFromAHeightAloneInAListOfNumbers() throws {
        let page = try lines([line("Text before the list."), [], line("[7] D. Lee, Title, Science 1, 2 (2018)."), line("[8] E. Kim, Title, Science 3, 4 (2021).")])
        // A link that names only a height a little above the entry, and the page's left edge.
        let entry = PreviewText.entry(in: page, at: CGPoint(x: 0, y: top(ofLine: 2) + 3), knownX: false)
        XCTAssertEqual(entry.first?.text, "[7] D. Lee, Title, Science 1, 2 (2018).")
        XCTAssertEqual(entry.count, 1)
    }
}

/// Where a preview opens when a link names its place badly (ADR 0006).
final class PreviewTargetTests: XCTestCase {
    private typealias Run = TextPaper.Run
    private func line(_ text: String, size: Double = 10) -> [Run] { [(text, size, 0)] }
    private func top(ofLine n: Int) -> CGFloat { 740 + 10 - CGFloat(n) * 14 }

    func testACitationOpensOnItsEntryWhereverTheLinkPoints() throws {
        let document = try XCTUnwrap(PDFDocument(data: TextPaper.data([
            [line("Running text that cites [3] and [12].")],
            [line("References"), line("[11] A. Lee, Title, Nature 1, 2 (2017)."), line("[12] B. Kim, Title, Science 3, 4 (2018)."),
             line("and more of the same entry."), line("[13] C. Wu, Title, Phys. Rev. B 5, 6 (2019).")],
        ])))
        // The link names a height two lines above its entry, and no column.
        let found = try XCTUnwrap(PreviewTarget.find(text: "12", page: 1, point: CGPoint(x: 0, y: top(ofLine: 1) + 4),
                                                     in: document, bodySize: 10, from: 0))
        XCTAssertEqual(found.point.y, top(ofLine: 2), accuracy: 3)
        XCTAssertTrue(found.inColumn)
        XCTAssertEqual(found.entry.map(\.text), ["[12] B. Kim, Title, Science 3, 4 (2018).", "and more of the same entry."])
        XCTAssertNil(PreviewTarget.find(text: "12", page: 1, point: nil, in: document, bodySize: 10, from: 1),
                     "a number leading to its own page is no citation")
        XCTAssertNil(PreviewTarget.find(text: "40", page: 1, point: nil, in: document, bodySize: 10, from: 0), "no such entry")
    }

    func testTheNumbersACitationIsWrittenWith() {
        XCTAssertEqual(PreviewTarget.firstNumber("[67]"), 67)
        XCTAssertNil(PreviewTarget.firstNumber("2019"), "a year linked in an author-year citation")
        XCTAssertEqual(PreviewTarget.firstNumber("3–5"), 3)
        XCTAssertEqual(PreviewTarget.firstNumber("1,2"), 1)
        XCTAssertNil(PreviewTarget.firstNumber("Fig. 2"))
        XCTAssertTrue(PreviewTarget.starts("[67] P. Giannozzi", with: 67))
        XCTAssertTrue(PreviewTarget.starts("67. Smith, A.", with: 67))
        XCTAssertTrue(PreviewTarget.starts("67.", with: 67))
        XCTAssertFalse(PreviewTarget.starts("[670] P. Giannozzi", with: 67))
        XCTAssertFalse(PreviewTarget.starts("(2009).", with: 2009) && PreviewTarget.starts("(2009).", with: 9))
    }
}

final class SearchOptionsTests: XCTestCase {
    func testAWholeWordStandsApartFromLettersAndDigits() {
        XCTAssertTrue(SearchOptions.isWholeWord("band", before: " ", after: " "))
        XCTAssertTrue(SearchOptions.isWholeWord("band", before: nil, after: "."))
        XCTAssertFalse(SearchOptions.isWholeWord("band", before: " ", after: "s"), "inside bands")
        XCTAssertFalse(SearchOptions.isWholeWord("band", before: "s", after: " "), "inside subband")
        XCTAssertFalse(SearchOptions.isWholeWord("Cu", before: " ", after: "2"))
        XCTAssertTrue(SearchOptions.isWholeWord("Cu-", before: " ", after: "N"), "a match ending in a hyphen needs nothing after it")
    }
}

final class EntryAcrossColumnsTests: XCTestCase {
    private func line(_ text: String, x: CGFloat, top: CGFloat) -> PreviewText.Line {
        PreviewText.Line(text: text, rect: CGRect(x: x, y: top - 10, width: 220, height: 10))
    }

    func testAnEntryAtTheFootOfAColumnGoesOnAtTheHeadOfTheNext() {
        let lines = [
            line("[11] A. Lee, Title of a work that runs long,", x: 50, top: 120),
            line("Phys. Rev. B 12,", x: 60, top: 108),
            line("345 (2019).", x: 320, top: 700),
            line("[12] B. Kim, Another, Nature 5, 6 (2020).", x: 310, top: 688),
        ]
        let (entry, runsOn) = PreviewText.entryRunning(in: lines, startingAt: 0)
        XCTAssertEqual(entry.map(\.text), ["[11] A. Lee, Title of a work that runs long,", "Phys. Rev. B 12,", "345 (2019)."])
        XCTAssertFalse(runsOn)
    }

    func testAnEntryEndingAtTheFootOfAColumnTakesNothingFromTheNext() {
        let lines = [
            line("[11] A. Lee, Title, Phys. Rev. B 12, 345 (2019).", x: 50, top: 120),
            line("[12] B. Kim, Another, Nature 5, 6 (2020).", x: 310, top: 700),
        ]
        XCTAssertEqual(PreviewText.entryRunning(in: lines, startingAt: 0).lines.count, 1)
    }

    func testAnEntryAtTheFootOfThePageGoesOnOverleaf() {
        let page = [line("[11] A. Lee, Title of a work that runs", x: 50, top: 120)]
        let (_, runsOn) = PreviewText.entryRunning(in: page, startingAt: 0)
        XCTAssertTrue(runsOn)
        let overleaf = [line("Running head of the journal", x: 50, top: 780), line("long, Phys. Rev. B 12, 345 (2019).", x: 50, top: 720),
                        line("[12] B. Kim, Another (2020).", x: 50, top: 708)]
        XCTAssertEqual(PreviewText.continuation(in: overleaf, pageHeight: 792, top: 792, of: page).map(\.text), ["long, Phys. Rev. B 12, 345 (2019)."])
    }

    func testAFooterOrBodyTextIsNotTakenForTheRestOfAnEntry() {
        let entry = line("[11] A. Lee, Title of a work that runs", x: 50, top: 120)
        // The next column holds a download notice, then nothing below it.
        let notice = [entry, line("Downloaded from https://pubs.acs.org on 3 May 2024", x: 320, top: 700),
                      line("[12] B. Kim, Another (2020).", x: 320, top: 688)]
        XCTAssertEqual(PreviewText.entryRunning(in: notice, startingAt: 0).lines.count, 1)
        // The next column is body text: no entry follows it.
        let body = [entry, line("The presence of these states shows that", x: 320, top: 700), line("the bands cross near the Fermi level.", x: 320, top: 688)]
        XCTAssertEqual(PreviewText.entryRunning(in: body, startingAt: 0).lines.count, 1)
        // Overleaf, a chapter heading in larger type.
        let heading = [PreviewText.Line(text: "Conclusions and future work", rect: CGRect(x: 50, y: 680, width: 300, height: 18)),
                       line("[12] B. Kim, Another (2020).", x: 50, top: 650)]
        XCTAssertTrue(PreviewText.continuation(in: heading, pageHeight: 792, top: 792, of: [entry]).isEmpty)
    }
}
