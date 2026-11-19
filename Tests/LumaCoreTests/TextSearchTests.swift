import XCTest
@testable import LumaCore

final class TextSearchTests: XCTestCase {
    private func found(_ query: String, in text: String, _ options: SearchOptions = SearchOptions()) -> [String] {
        TextSearch.ranges(of: query, in: text, options: options).map { (text as NSString).substring(with: $0) }
    }

    func testAPhraseRunsOntoTheNextLine() {
        let title = "water splitting and hydrogen evolution\nreaction on grain boundaries"
        XCTAssertEqual(found("hydrogen evolution reaction on grain", in: title), ["hydrogen evolution\nreaction on grain"])
        XCTAssertEqual(found("HYDROGEN   evolution", in: title), ["hydrogen evolution"])
        XCTAssertEqual(found("evolution reaction", in: "evolution \r\n  reaction"), ["evolution \r\n  reaction"])
    }

    func testAWordHyphenatedAtALineBreak() {
        XCTAssertEqual(found("evolution", in: "the evolu-\ntion of"), ["evolu-\ntion"])
        XCTAssertEqual(found("evolu-tion", in: "the evolu-\ntion of"), ["evolu-\ntion"])
        // A hyphen that belongs to the word stays one too.
        XCTAssertEqual(found("GB-containing", in: "of GB-\ncontaining films"), ["GB-\ncontaining"])
        XCTAssertEqual(found("10-20", in: "pages 10-\n20 and"), ["10-\n20"])
        XCTAssertEqual(found("10- 20", in: "pages 10-\n20 and"), ["10-\n20"])
        // A hyphen with a space after it on the same line is not a broken word.
        XCTAssertEqual(found("CuAg", in: "Cu- and Ag-"), [])
        XCTAssertEqual(found("softword", in: "soft\u{AD}word"), ["soft\u{AD}word"])
    }

    func testCaseAndAccents() {
        XCTAssertEqual(found("cafe", in: "un Café noir"), ["Café"])
        XCTAssertEqual(found("cafe", in: "un cafe\u{301} noir"), ["cafe\u{301}"])
        XCTAssertEqual(found("Band", in: "band Band", SearchOptions(matchCase: true)), ["Band"])
        XCTAssertEqual(found("fi", in: "\u{FB01}nd"), ["\u{FB01}"])
        XCTAssertEqual(found("α-β", in: "α\u{2010}β"), ["α\u{2010}β"])
    }

    func testWholeWordsAndOverlaps() {
        XCTAssertEqual(found("band", in: "bands band subband", SearchOptions(wholeWords: true)), ["band"])
        XCTAssertEqual(found("aa", in: "aaaa"), ["aa", "aa"])
        XCTAssertEqual(found("", in: "text"), [])
        XCTAssertEqual(found("  \n", in: "a b"), [])
        XCTAssertEqual(found("x", in: ""), [])
    }

    func testRangesCountUTF16Units() {
        let text = "𝑥 = hydrogen\nevolution"
        let range = TextSearch.ranges(of: "hydrogen evolution", in: text)
        XCTAssertEqual(range, [NSRange(location: 5, length: 18)])
    }
}
