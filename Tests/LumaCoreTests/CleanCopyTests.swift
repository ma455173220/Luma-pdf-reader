import CoreGraphics
import XCTest
@testable import LumaCore

final class CleanCopyTests: XCTestCase {
    /// Lines of a single column, 12 points apart, 10 points tall, 300 wide, from the top of the page.
    private func column(_ texts: [String], x: CGFloat = 72, width: CGFloat = 300, top: CGFloat = 700, page: Int = 0,
                        widths: [Int: CGFloat] = [:], indents: [Int: CGFloat] = [:]) -> [CleanCopy.Line] {
        texts.enumerated().map { i, text in
            let left = x + (indents[i] ?? 0)
            return CleanCopy.Line(text: text, frame: CGRect(x: left, y: top - CGFloat(i) * 12, width: (widths[i] ?? width) - (indents[i] ?? 0), height: 10), page: page)
        }
    }

    // What a spelling dictionary would say, including its habit of accepting odd joins.
    private let words: Set<String> = ["electrochemical", "reduction", "catalysis", "xray", "αhelix"]
    private func isWord(_ s: String) -> Bool { words.contains(s.lowercased()) }

    func testLinesOfAParagraphAreJoinedWithSpaces() {
        let lines = column(["The surface states of the", "monolayer govern its", "catalytic activity."])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "The surface states of the monolayer govern its catalytic activity.")
    }

    func testAWordSplitAtTheEndOfALineIsMended() {
        let lines = column(["a study of electro-", "chemical behaviour"])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "a study of electrochemical behaviour")
    }

    func testAHyphenThatBelongsToTheWordIsKeptWithoutASpace() {
        let lines = column(["in two-", "dimensional materials"])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "in two-dimensional materials")
    }

    func testAHyphenBeforeACapitalIsKept() {
        let lines = column(["the Hartree-", "Fock method"])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "the Hartree-Fock method")
    }

    func testJoinedLettersAreSpelledOutAndSoftHyphensDropped() {
        let lines = column(["the \u{FB01}rst e\u{FB03}cient cata\u{00AD}lyst"])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "the first efficient catalyst")
    }

    func testAShortLineEndingASentenceEndsTheParagraph() {
        let lines = column(["The first paragraph runs across", "two lines.", "The second one follows it on"], widths: [1: 80])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "The first paragraph runs across two lines.\nThe second one follows it on")
    }

    func testAnIndentedLineStartsANewParagraph() {
        let lines = column(["ends here at the margin.", "A new paragraph starts", "and goes on."], indents: [1: 15])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "ends here at the margin.\nA new paragraph starts and goes on.")
    }

    func testAWideGapStartsANewParagraph() {
        var lines = column(["Last line of one paragraph", "first line of the next"])
        lines[1].frame.origin.y -= 18
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "Last line of one paragraph\nfirst line of the next")
    }

    func testAParagraphCarriesOnIntoTheNextColumnAndPage() {
        let left = column(["the reaction proceeds through"], x: 72, width: 220)
        let right = column(["an intermediate state"], x: 320, width: 220, top: 760)
        let nextPage = column(["of low energy."], top: 760, page: 1)
        XCTAssertEqual(CleanCopy.text(from: left + right + nextPage, isWord: isWord),
                       "the reaction proceeds through an intermediate state of low energy.")
    }

    func testChineseLinesAreJoinedWithoutASpace() {
        let lines = column(["拓扑表面态决定了", "催化活性。"])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "拓扑表面态决定了催化活性。")
    }

    func testASoftHyphenAtTheEndOfALineJoinsTheWordWithoutASpace() {
        let lines = column(["a study of electro\u{00AD}", "chemical behaviour"])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "a study of electrochemical behaviour")
    }

    func testGreekLettersAndSingleLettersKeepTheirHyphen() {
        XCTAssertEqual(CleanCopy.text(from: column(["an α-", "helix forms"]), isWord: isWord), "an α-helix forms")
        XCTAssertEqual(CleanCopy.text(from: column(["by X-", "ray diffraction"]), isWord: isWord), "by X-ray diffraction")
    }

    func testDashesAfterDigitsAreKeptWithoutASpace() {
        XCTAssertEqual(CleanCopy.text(from: column(["MoS2-", "based catalysts"]), isWord: isWord), "MoS2-based catalysts")
        XCTAssertEqual(CleanCopy.text(from: column(["pages 10\u{2013}", "20 of the review"]), isWord: isWord), "pages 10\u{2013}20 of the review")
    }

    func testDoubleSpacedLinesStillMakeOneParagraph() {
        var lines = column(["Lines of a typescript are set", "far apart, yet they are one", "paragraph all the same"])
        for i in lines.indices { lines[i].frame.origin.y -= CGFloat(i) * 12 }      // 24 points apart instead of 12
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "Lines of a typescript are set far apart, yet they are one paragraph all the same")
    }

    func testReferencesWithHangingIndentsSplitAtEachEntry() {
        let lines = column(["[1] A. Author, J. Phys. 12,", "345 (2020).", "[2] B. Author, Nature 5,", "67 (2021)."], indents: [1: 15, 3: 15])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "[1] A. Author, J. Phys. 12, 345 (2020).\n[2] B. Author, Nature 5, 67 (2021).")
    }

    func testAWideCaptionDoesNotBreakTheColumnAtEveryFullStop() {
        let lines = column(["as reported in Ref.", "12, the gap closes at the", "Dirac point and then opens", "again under strain in the", "Figure 2. A caption across both columns runs on."],
                           width: 224, widths: [4: 468])
        XCTAssertTrue(CleanCopy.text(from: onPage(lines), isWord: isWord).hasPrefix("as reported in Ref. 12, the gap"))
    }

    private func onPage(_ lines: [CleanCopy.Line]) -> [CleanCopy.Line] {
        lines.map { var line = $0; line.pageBox = CGRect(x: 0, y: 0, width: 612, height: 792); return line }
    }

    /// What the pages around would say recurs in their top and bottom strips.
    private let recurring: Set<String> = [CleanCopy.runningKey("J. Phys.: Condens. Matter 36 (2024) 165201"),
                                          CleanCopy.runningKey("Journal of Things 36 (2024) 165201")]
    /// Page numbers near 3 to 7 recur on the pages around; other numbers (a year) do not.
    private func isRunning(_ line: CleanCopy.Line) -> Bool {
        if let number = CleanCopy.bareNumber(line.text) { return (1...9).contains(number) }
        return recurring.contains(CleanCopy.runningKey(line.text))
    }

    func testAPageNumberBetweenPagesIsLeftOut() {
        let end = column(["the reaction proceeds through"], width: 300)
        let number = column(["7"], x: 290, width: 10, top: 40)
        let next = column(["an intermediate state."], top: 700, page: 1)
        XCTAssertEqual(CleanCopy.text(from: onPage(end + number + next), isWord: isWord, isRunning: isRunning),
                       "the reaction proceeds through an intermediate state.")
    }

    func testRunningHeadsAndFeetAtAPageTurnAreLeftOut() {
        let end = column(["the reaction proceeds through"], top: 700)
        let foot = column(["Journal of Things 36 (2024) 165201", "3"], x: 72, top: 45)
        let head = column(["J. Phys.: Condens. Matter 36 (2024) 165201"], top: 770, page: 1)
        let next = column(["an intermediate state."], top: 700, page: 1)
        XCTAssertEqual(CleanCopy.text(from: onPage(end + foot + head + next), isWord: isWord, isRunning: isRunning),
                       "the reaction proceeds through an intermediate state.")
    }

    func testBodyTextNearThePageEdgeIsKeptWhenItDoesNotRecur() {
        // The last line of one page and the first of the next both sit in the strips, as in many journals.
        let end = column(["catalysts are thought to work by"], top: 60)
        let next = column(["lowering the barrier of the first step."], top: 760, page: 1)
        XCTAssertEqual(CleanCopy.text(from: onPage(end + next), isWord: isWord, isRunning: isRunning),
                       "catalysts are thought to work by lowering the barrier of the first step.")
    }

    func testAYearOnItsOwnLineInTheBodyIsKept() {
        let end = column(["Nature Physics 12, 345,"], top: 400)
        let next = column(["2020", "and later work."], top: 770, page: 1)
        XCTAssertEqual(CleanCopy.text(from: onPage(end + next), isWord: isWord, isRunning: isRunning), "Nature Physics 12, 345, 2020 and later work.")
    }

    func testTextAtTheTopOfTheFirstPageSelectedIsKept() {
        let lines = column(["J. Phys.: Condens. Matter 36 (2024)", "a heading of the page"], top: 770)
        XCTAssertEqual(CleanCopy.text(from: onPage(lines), isWord: isWord), "J. Phys.: Condens. Matter 36 (2024) a heading of the page")
    }

    func testAHeadingInLargerTypeIsKeptApart() {
        var lines = column(["Introduction", "Topological materials have"], widths: [0: 100])
        lines[0].frame.size.height = 14
        lines[0].frame.origin.y += 2
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "Introduction\nTopological materials have")
    }

    func testALineMadeTallerByASuperscriptDoesNotBreakTheParagraph() {
        var lines = column(["as shown before\u{00B9}\u{00B2} the surface states", "govern the activity"])
        lines[0].frame.size.height = 14
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "as shown before\u{00B9}\u{00B2} the surface states govern the activity")
    }

    func testASelectionStartingMidLineIsNotTakenForAList() {
        // The first line starts mid-way, so it looks set in; the second happens to start with a reference.
        let lines = column(["oxygen reductions", "[9–19] (HER or OER) have been studied"], indents: [0: 150])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "oxygen reductions [9–19] (HER or OER) have been studied")
    }

    func testIndentedParagraphsWhoseLinesStartWithNumbersStayParagraphs() {
        let lines = column(["The sample was cooled to", "300 K and then measured.", "Another paragraph starts", "40 minutes later."], indents: [0: 15, 2: 15])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "The sample was cooled to 300 K and then measured.\nAnother paragraph starts 40 minutes later.")
    }

    func testTwoDoubleSpacedLinesStayOneParagraph() {
        var lines = column(["Lines of a typescript are set", "far apart all the same"])
        lines[1].frame.origin.y -= 12
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "Lines of a typescript are set far apart all the same")
    }

    func testAWideCaptionAmongFewLinesDoesNotBreakAtFullStops() {
        let lines = column(["as reported in Ref.", "12, the gap closes at the", "Figure 2. A caption across both columns runs on."], width: 224, widths: [2: 468])
        XCTAssertTrue(CleanCopy.text(from: onPage(lines), isWord: isWord).hasPrefix("as reported in Ref. 12, the gap"))
    }

    func testASlightlyLargerHeadingIsKeptApart() {
        var lines = column(["Methods", "The samples were grown by"], widths: [0: 80])
        lines[0].frame.size.height = 12
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "Methods\nThe samples were grown by")
    }

    func testASoftHyphenBeforeAnIndentedLineStillJoinsTheWord() {
        let lines = column(["a study of electro\u{00AD}", "chemical behaviour"], indents: [1: 15])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "a study of electrochemical behaviour")
    }

    func testDashesAfterBracketsAndEmDashesJoinWithoutASpace() {
        XCTAssertEqual(CleanCopy.text(from: column(["Fe(III)-", "containing films"]), isWord: isWord), "Fe(III)-containing films")
        XCTAssertEqual(CleanCopy.text(from: column(["the effect\u{2014}", "which is small"]), isWord: isWord), "the effect\u{2014}which is small")
    }

    func testASingleReferenceWithAHangingIndentStaysTogether() {
        let lines = column(["[2] B. Author, Nature 5,", "67 (2021)."], indents: [1: 15])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "[2] B. Author, Nature 5, 67 (2021).")
    }

    func testAShortLastLineBeforeTwoLinesOfTheNextParagraphEndsIt() {
        let lines = column(["ends the paragraph.", "The next paragraph runs across", "two lines"], widths: [0: 120, 2: 90])
        XCTAssertEqual(CleanCopy.text(from: onPage(lines), isWord: isWord), "ends the paragraph.\nThe next paragraph runs across two lines")
    }

    func testACaptionAcrossBothColumnsDoesNotMoveTheColumnEdge() {
        // Left column of a two-column page: x 72 to 296; the caption runs across to 540.
        let lines = column(["as reported in Ref.", "12, the gap closes at the", "Dirac point and then opens", "Figure 2. A caption across both columns of the page."],
                           width: 224, widths: [3: 468])
        XCTAssertTrue(CleanCopy.text(from: onPage(lines), isWord: isWord).hasPrefix("as reported in Ref. 12, the gap"))
    }

    func testAParagraphEndingWithAReferenceToSourcesEndsBeforeAnIndentedLine() {
        for ending in ["activity.[57]", "activity.43", "activity.\u{2074}\u{00B3}", "activity.[12,13]"] {
            let lines = column(["the selectivity improves the " + ending, "Finally, the selectivity rises"], indents: [1: 15])
            XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "the selectivity improves the \(ending)\nFinally, the selectivity rises", ending)
        }
    }

    func testAReferenceWhoseFirstLineEndsOnAnAbbreviationStaysTogether() {
        let lines = column(["[42] X. Li, H. Wang, J.", "Am. Chem. Soc. 2017, 139, 9771."], indents: [1: 15])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "[42] X. Li, H. Wang, J. Am. Chem. Soc. 2017, 139, 9771.")
        let other = column(["[7] A. Author, Nat.", "Commun. 5, 67 (2021)."], indents: [1: 15])
        XCTAssertEqual(CleanCopy.text(from: other, isWord: isWord), "[7] A. Author, Nat. Commun. 5, 67 (2021).")
    }

    func testOneLineSetALittleWideDoesNotMoveTheColumnEdge() {
        let lines = column(["devices built on monolayer MoS2.", "Nano Lett. 10, 1271\u{2013}1275 (2010).", "Later work reached higher"], widths: [0: 300, 1: 306, 2: 300])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "devices built on monolayer MoS2. Nano Lett. 10, 1271\u{2013}1275 (2010). Later work reached higher")
    }

    func testShortLinesOnTheLeftOfASingleColumnDoNotMoveTheEdge() {
        let lines = column(["A paragraph ending here.", "A new one whose first line is full", "and goes on short.", "Then another"], widths: [0: 150, 2: 120, 3: 90])
        XCTAssertEqual(CleanCopy.text(from: onPage(lines), isWord: isWord),
                       "A paragraph ending here.\nA new one whose first line is full and goes on short.\nThen another")
    }

    func testAnEntryNumberStandingAloneJoinsItsEntry() {
        let lines = column(["51. Bader, R. F. W. Atoms in Molecules.", "52.", "Pavone, M. Quantum-Mechanics-Based Design."], widths: [1: 20])
        XCTAssertEqual(CleanCopy.text(from: lines, isWord: isWord), "51. Bader, R. F. W. Atoms in Molecules.\n52. Pavone, M. Quantum-Mechanics-Based Design.")
    }

    func testNothingSelectedGivesNothing() {
        XCTAssertEqual(CleanCopy.text(from: [], isWord: isWord), "")
        XCTAssertEqual(CleanCopy.text(from: column(["  "]), isWord: isWord), "")
    }
}
