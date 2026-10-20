import PDFKit
import XCTest
@testable import LumaCore

final class AppendWriterTests: XCTestCase {
    private let note = "知白 测试附注"

    private func highlight(page: Int = 0) -> MarkupAddition {
        MarkupAddition(pageIndex: page, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)],
                       red: 1, green: 0.92, blue: 0.23, note: note)
    }

    private func append(to bytes: [UInt8], page: Int = 0) throws -> [UInt8] {
        [UInt8](try PDFAppendWriter.appending([highlight(page: page)], to: Data(bytes)))
    }

    /// The annotation list of page 1 as the strict reader sees it in `bytes`.
    private func annotationList(_ bytes: [UInt8]) throws -> [PDFValue] {
        let structure = try PDFStructure(bytes)
        let page = try structure.object(structure.pageNumbers()[0])
        let lists = page.entries?.filter { $0.key == "Annots" } ?? []
        XCTAssertEqual(lists.count, 1, "page must carry exactly one annotation list")
        return try structure.resolve(lists.first?.value ?? .null).array ?? []
    }

    /// The file must be turned away, and for the stated reason. A refusal for some other reason
    /// would mean the check under test never ran.
    private func assertRefused(_ bytes: [UInt8], because expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try append(to: bytes), "the file was accepted", file: file, line: line) { error in
            guard let appendError = error as? PDFAppendError else {
                return XCTFail("unexpected error type: \(error)", file: file, line: line)
            }
            if case .selfCheckFailed = appendError {
                XCTFail("writer produced output it then rejected: \(appendError)", file: file, line: line)
            }
            XCTAssertTrue(appendError.description.contains(expected),
                          "refused for another reason: \"\(appendError.description)\", expected one mentioning \"\(expected)\"", file: file, line: line)
        }
    }

    /// The result must start with the original, read the same in the system engine, and keep the old note.
    private func assertGoodResult(_ original: [UInt8], _ result: [UInt8], expectOldNote: Bool = true,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(result.prefix(original.count)), original, "original bytes must be untouched", file: file, line: line)
        guard let before = PDFDocument(data: Data(original)), let after = PDFDocument(data: Data(result)) else {
            return XCTFail("system engine cannot open the files", file: file, line: line)
        }
        XCTAssertEqual(after.pageCount, before.pageCount, file: file, line: line)
        for index in 0..<before.pageCount {
            XCTAssertEqual(after.page(at: index)?.string, before.page(at: index)?.string, "text of page \(index + 1)", file: file, line: line)
            XCTAssertEqual(after.page(at: index)?.bounds(for: .mediaBox), before.page(at: index)?.bounds(for: .mediaBox), file: file, line: line)
        }
        let kinds = after.page(at: 0)?.annotations ?? []
        XCTAssertTrue(kinds.contains { $0.type == "Highlight" && $0.contents == note }, "new highlight with its note", file: file, line: line)
        if expectOldNote {
            XCTAssertTrue(kinds.contains { $0.type == "Text" && $0.contents == "old note" }, "existing note must survive", file: file, line: line)
        }
    }

    // MARK: Files that must work

    func testOldStyleIndexWithInlineList() throws {
        let original = MiniPDF().classic()
        let result = try append(to: original)
        assertGoodResult(original, result)
        XCTAssertEqual(try annotationList(result).count, 2)
    }

    func testListStoredAsSeparateObject() throws {
        var file = MiniPDF()
        file.annotations = .separateList
        let original = file.classic()
        let result = try append(to: original)
        assertGoodResult(original, result)
        XCTAssertEqual(try annotationList(result).count, 2)
    }

    func testPageWithoutAnyAnnotations() throws {
        var file = MiniPDF()
        file.annotations = .none
        let original = file.classic()
        let result = try append(to: original)
        assertGoodResult(original, result, expectOldNote: false)
        XCTAssertEqual(try annotationList(result).count, 1)
    }

    func testCompressedIndexAndPackedPage() throws {
        let original = MiniPDF().compressed()
        let result = try append(to: original)
        assertGoodResult(original, result)
        XCTAssertTrue(try PDFStructure(result).newestIsStream, "a compressed index must be extended with another one")
    }

    /// Nearly every real compressed index is stored with a row predictor.
    func testCompressedIndexStoredWithPredictor() throws {
        let original = MiniPDF().compressed(usePredictor: true)
        assertGoodResult(original, try append(to: original))
    }

    func testSecondSaveOnTopOfFirst() throws {
        for original in [MiniPDF().classic(), MiniPDF().compressed()] {
            let once = try append(to: original)
            let twice = try append(to: once, page: 1)
            assertGoodResult(original, twice)
            XCTAssertEqual(Array(twice.prefix(once.count)), once)
            let after = try XCTUnwrap(PDFDocument(data: Data(twice)))
            XCTAssertTrue(after.page(at: 1)?.annotations.contains { $0.type == "Highlight" } ?? false)
        }
    }

    func testSeveralMarksInOneSave() throws {
        let original = MiniPDF().classic()
        let marks = [highlight(page: 0), highlight(page: 1), highlight(page: 0)]
        let result = [UInt8](try PDFAppendWriter.appending(marks, to: Data(original)))
        assertGoodResult(original, result)
        XCTAssertEqual(try annotationList(result).count, 3)
    }

    func testPageWithNonZeroGeneration() throws {
        var file = MiniPDF()
        file.pageGeneration = 1
        let original = file.classic()
        assertGoodResult(original, try append(to: original))
    }

    func testPageSizeInheritedFromParent() throws {
        var file = MiniPDF()
        file.inheritPageSize = true
        let original = file.classic()
        assertGoodResult(original, try append(to: original))
    }

    /// `/A#6Enots` is a legal way to spell `/Annots`. It must be recognised, or the page ends up
    /// with two lists and the existing note is lost.
    func testEscapedPropertyName() throws {
        var file = MiniPDF()
        file.annotationsKey = "/A#6Enots"
        let original = file.classic()
        let result = try append(to: original)
        assertGoodResult(original, result)
        XCTAssertEqual(try annotationList(result).count, 2)
    }

    /// A later save replaced the page under the same version number; the newer version is the one to extend.
    func testNewerVersionOfPageWins() throws {
        let base = MiniPDF().classic()
        let newerPage = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 9 0 R >> >> >>"
        let original = MiniPDF.update(base, objects: [(3, 0, newerPage)])
        let result = try append(to: original)
        let after = try XCTUnwrap(PDFDocument(data: Data(result)))
        XCTAssertEqual(after.page(at: 0)?.string, PDFDocument(data: Data(original))?.page(at: 0)?.string)
        XCTAssertEqual(try annotationList(result).count, 1)
    }

    /// A deleted object the page does not depend on is no reason to refuse the file.
    func testUnrelatedDeletedObjectIsNoObstacle() throws {
        var file = MiniPDF()
        file.extraObjects = [(12, 0, "<< /Unrelated true >>")]
        let original = MiniPDF.update(file.classic(), freed: [12])
        assertGoodResult(original, try append(to: original))
    }

    // MARK: Harmless quirks that must not cause a refusal

    /// Some writers point each index entry at the line break just before the object.
    func testIndexPointingAtBlankSpaceBeforeObjectIsAccepted() throws {
        var original = MiniPDF().classic()
        original.insert(0x0A, at: 9)
        assertGoodResult(original, try append(to: original))
    }

    func testCompressedIndexAndPackPointedAtWithBlankSpaceAreAccepted() throws {
        let original = MiniPDF().compressed(blankBeforeObjects: true)
        assertGoodResult(original, try append(to: original))
    }

    /// macOS's own PDF writer lists numbers it never used as "in use at position 0".
    func testUnusedSlotMarkedInUseIsAccepted() throws {
        var file = MiniPDF()
        file.unusedSlotMarkedInUse = true
        let original = file.classic()
        assertGoodResult(original, try append(to: original))
    }

    /// A publisher's usage-rights seal is not a certification; such papers must stay annotatable.
    func testUsageRightsSealIsAccepted() throws {
        var file = MiniPDF()
        file.catalogExtras = MiniPDF.usageRightsSeal
        let original = file.classic()
        assertGoodResult(original, try append(to: original))
    }

    // MARK: Conflicting index sections — readers disagree, so the writer must not guess

    /// A list that a later save deleted: the format says it is gone, the system engine still shows it.
    func testListDeletedByLaterSaveIsRefused() {
        var file = MiniPDF()
        file.annotations = .separateList
        assertRefused(MiniPDF.update(file.classic(), freed: [8]), because: "readers read differently")
    }

    /// The same deletion, recorded in the compressed half of a hybrid index.
    func testListDeletedInCompressedHalfOfHybridIndexIsRefused() {
        var file = MiniPDF()
        file.annotations = .separateList
        assertRefused(MiniPDF.update(file.classic(), freedInCompressedPart: [8]), because: "readers read differently")
    }

    /// A newer section says "in use at position 0" for a number that an older section gives a real object.
    func testPlaceholderShadowingARealObjectIsRefused() {
        var file = MiniPDF()
        file.annotations = .separateList
        assertRefused(MiniPDF.update(file.classic(), placeholders: [8]), because: "readers read differently")
    }

    /// The list's number was reused under a new version; the page's reference to the old version is dead.
    func testReferenceToOutdatedVersionIsRefused() {
        var file = MiniPDF()
        file.annotations = .separateList
        assertRefused(MiniPDF.update(file.classic(), objects: [(8, 1, "[]")]), because: "outdated version")
    }

    /// The list was deleted and its number given, under a new version, to a new list, and the page
    /// refers to that new version. Every reader follows this the same way; it is no reason to refuse.
    func testNumberReusedUnderANewVersionWithCorrectReferenceIsAccepted() throws {
        var file = MiniPDF()
        file.annotations = .separateList
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >> /Annots 8 1 R >>"
        let original = MiniPDF.update(file.classic(), objects: [(8, 1, "[7 0 R]"), (3, 0, page)])
        let result = try append(to: original)
        assertGoodResult(original, result)
        XCTAssertEqual(try annotationList(result).count, 2)
    }

    /// Entries saying "inside pack 10" were written for the pack that was there then.
    func testObjectPackReplacedByLaterSaveIsRefused() {
        let replacement = "<< /Type /ObjStm /N 0 /First 0 /Length 0 >>\nstream\n\nendstream"
        assertRefused(MiniPDF.update(MiniPDF().compressed(), objects: [(10, 0, replacement)]), because: "replaced or removed")
    }

    /// A hybrid index whose old-style table marks an object deleted while its compressed half says it
    /// is in use. Readers disagree about such an object (one shows it, one does not, one repairs the
    /// file first), so the file is left alone. Hybrid files that simply leave the object out of the
    /// table are another matter, and are accepted.
    func testHybridIndexWhoseHalvesDisagreeIsRefused() {
        var file = MiniPDF()
        file.annotations = .none
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >> /Annots 12 0 R >>"
        let original = MiniPDF.update(file.classic(), objects: [(3, 0, page)], freed: [12], liveInCompressedPart: [(12, "[7 0 R]")])
        assertRefused(original, because: "hybrid index disagree")
    }

    // MARK: Files that must be turned away

    func testTruncatedCompressedIndexIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .truncatedIndex), because: "does not decompress cleanly")
    }

    func testCompressedIndexWithTooFewRowsIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .shortIndex), because: "shorter than it declares")
    }

    func testPackHoldingTheWrongObjectIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .wrongObjectInPack), because: "object pack does not hold")
    }

    func testPreviousIndexPointerOutsideFileIsRefused() {
        assertRefused(MiniPDF.update(MiniPDF().classic(), previousPointer: "99999999"), because: "outside the file")
    }

    func testUnreadablePreviousIndexPointerIsRefused() {
        assertRefused(MiniPDF.update(MiniPDF().classic(), previousPointer: "(oops)"), because: "not a plain number")
    }

    func testAnnotationListThatIsNotAListIsRefused() {
        var file = MiniPDF()
        file.annotations = .notAList
        assertRefused(file.classic(), because: "is not a list")
    }

    func testAnnotationListHoldingSomethingElseIsRefused() {
        var file = MiniPDF()
        file.annotations = .withStrayItem
        assertRefused(file.classic(), because: "not an annotation")
    }

    func testDuplicateAnnotationListIsRefused() {
        var file = MiniPDF()
        file.duplicateAnnotationsKey = true
        assertRefused(file.classic(), because: "same property twice")
    }

    func testPasswordProtectedFileIsRefused() {
        var file = MiniPDF()
        file.encrypted = true
        assertRefused(file.classic(), because: "password-protected")
    }

    /// The object the page needs is fine, but its index entry leads to a different object.
    func testIndexEntryForNeededObjectPointingAtAnotherObjectIsRefused() {
        var file = MiniPDF()
        file.swappedIndexEntries = (5, 6)
        assertRefused(file.classic(), because: "wrong object")
    }

    /// Only the font's entry is wrong. The writer never reads the font, so nothing but the
    /// entry-by-entry check of the whole index can notice.
    func testIndexEntryForUnneededObjectPointingAtAnotherObjectIsRefused() {
        var file = MiniPDF()
        file.extraObjects = [(12, 0, "<< /Unrelated true >>")]
        file.swappedIndexEntries = (9, 12)
        assertRefused(file.classic(), because: "wrong object")
    }

    func testIndexShiftedIntoThePreviousObjectIsRefused() {
        var bytes = MiniPDF().classic()
        // Three extra bytes after the header: the pointer to the index now lands inside the trailer.
        bytes.insert(contentsOf: Array("%x\n".utf8), at: 9)
        assertRefused(bytes, because: "does not lead to an index")
    }

    func testNotAPDFIsRefused() {
        assertRefused(Array("just some text".utf8), because: "PDF header")
        assertRefused([], because: "PDF header")
    }

    func testPageOutOfRangeIsRefused() {
        XCTAssertThrowsError(try append(to: MiniPDF().classic(), page: 5)) { error in
            XCTAssertEqual(error as? PDFAppendError, .refusedChange(0, "the page to annotate does not exist"))
        }
    }

    func testFileAtTheSizeCeilingIsRefused() {
        let original = MiniPDF().classic()
        XCTAssertThrowsError(try PDFAppendWriter.appending([highlight()], to: Data(original), sizeLimit: original.count)) { error in
            XCTAssertEqual(error as? PDFAppendError, .refused("file is larger than 4 GB"))
        }
        // Small enough to open, but the update would carry it over the ceiling.
        XCTAssertThrowsError(try PDFAppendWriter.appending([highlight()], to: Data(original), sizeLimit: original.count + 20)) { error in
            XCTAssertEqual(error as? PDFAppendError, .refused("file would grow past 4 GB"))
        }
    }

    // MARK: Signatures

    func testFormSayingSignaturesExistIsRefused() {
        var file = MiniPDF()
        file.catalogExtras = MiniPDF.formSayingSignaturesExist
        assertRefused(file.classic(), because: "digitally signed")
    }

    func testCertifiedFileIsRefused() {
        var file = MiniPDF()
        file.catalogExtras = MiniPDF.certification
        assertRefused(file.classic(), because: "certified")
    }

    /// No form and no flags: only the scan of the whole file for a signature's byte-range record can tell.
    func testSignatureFoundOnlyByScanningTheFileIsRefused() {
        var file = MiniPDF()
        file.extraObjects = [(12, 0, "<< /Type /Sig /ByteRange [0 1 2 3] >>")]
        assertRefused(file.classic(), because: "digitally signed")
    }

    func testSignatureFieldIsRefused() {
        var file = MiniPDF()
        file.catalogExtras = " /AcroForm << /Fields [12 0 R] >>"
        file.extraObjects = [(12, 0, "<< /FT /Sig /T (signature) >>")]
        assertRefused(file.classic(), because: "digitally signed")
    }

    func testSignatureFieldNestedInsideAnotherFieldIsRefused() {
        var file = MiniPDF()
        file.catalogExtras = " /AcroForm << /Fields [12 0 R] >>"
        file.extraObjects = [(12, 0, "<< /T (group) /Kids [13 0 R] >>"), (13, 0, "<< /FT /Sig /T (signature) /Parent 12 0 R >>")]
        assertRefused(file.classic(), because: "digitally signed")
    }

    /// A usage-rights seal must not hide a real signature that sits on a page without being listed in the form.
    func testSignatureNotListedInFormIsRefusedDespiteUsageRightsSeal() {
        var file = MiniPDF()
        file.catalogExtras = MiniPDF.usageRightsSeal
        file.extraObjects = [(12, 0, "<< /Type /Annot /Subtype /Widget /FT /Sig /Rect [0 0 0 0] /V << /Type /Sig /ByteRange [0 1 2 3] >> >>")]
        assertRefused(file.classic(), because: "digitally signed")
    }

    func testFormFieldsNestedTooDeeplyToCheckAreRefused() {
        var file = MiniPDF()
        file.catalogExtras = " /AcroForm << /Fields [100 0 R] >>"
        file.extraObjects = (100..<140).map { ($0, 0, "<< /T (level) /Kids [\($0 + 1) 0 R] >>") } + [(140, 0, "<< /FT /Sig >>")]
        assertRefused(file.classic(), because: "form fields are nested too deeply")
    }

    /// A field shared by two parents at every level doubles the number of paths at each step.
    /// Looked at once per field this is instant; looked at once per path it would take hours.
    func testTangledFormIsCheckedInReasonableTime() throws {
        var file = MiniPDF()
        file.catalogExtras = " /AcroForm << /Fields [100 0 R 100 0 R] >>"
        file.extraObjects = (100..<128).map { ($0, 0, "<< /T (level) /Kids [\($0 + 1) 0 R \($0 + 1) 0 R] >>") } + [(128, 0, "<< /T (leaf) >>")]
        let original = file.classic()
        let started = Date()
        assertGoodResult(original, try append(to: original))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// One seal reachable under two names is still one seal: a signature elsewhere must not hide behind it.
    func testSealListedUnderTwoNamesDoesNotExcuseAnotherSignature() {
        var file = MiniPDF()
        file.catalogExtras = " /Perms << /UR 12 0 R /UR3 12 0 R >> /AcroForm << /SigFlags 3 /Fields [] >>"
        file.extraObjects = [(12, 0, "<< /Type /Sig /ByteRange [0 1 2 3] >>"),
                             (13, 0, "<< /Type /Annot /Subtype /Widget /FT /Sig /Rect [0 0 0 0] /V << /Type /Sig /ByteRange [0 1 2 3] >> >>")]
        assertRefused(file.classic(), because: "digitally signed")
    }

    /// A later save may write the seal's object again. Both copies are the seal, not a second signature.
    func testSealRewrittenByLaterSaveIsStillOnlyASeal() throws {
        var file = MiniPDF()
        file.catalogExtras = " /Perms << /UR3 12 0 R >> /AcroForm << /SigFlags 3 /Fields [] >>"
        file.extraObjects = [(12, 0, "<< /Type /Sig /ByteRange [0 1 2 3] >>")]
        let original = MiniPDF.update(file.classic(), objects: [(12, 0, "<< /Type /Sig /ByteRange [0 1 2 3] /M (later) >>")])
        assertGoodResult(original, try append(to: original))
    }

    /// The same when the seal is written inside the document root and the root is saved again.
    func testInlineSealInRewrittenRootIsStillOnlyASeal() throws {
        var file = MiniPDF()
        file.catalogExtras = MiniPDF.usageRightsSeal
        let original = MiniPDF.update(file.classic(), objects: [(1, 0, "<< /Type /Catalog /Pages 2 0 R\(MiniPDF.usageRightsSeal) >>")])
        assertGoodResult(original, try append(to: original))
    }

    // MARK: Hostile numbers and shapes — refuse, never crash

    func testObjectNumberBeyondTheFormatLimitIsRefused() {
        let hostile = MiniPDF.update(MiniPDF().classic(), rawIndexLines: "9223372036854775807 1\n0000000010 00000 n \n")
        assertRefused(hostile, because: "beyond what the format allows")
    }

    func testImpossibleDeclaredSizeIsRefused() {
        assertRefused(MiniPDF.update(MiniPDF().classic(), size: "9223372036854775807"), because: "does not declare a usable size")
    }

    func testOversizedCompressedIndexFieldIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .oversizedField), because: "too large to be real")
    }

    func testDeeplyNestedObjectIsRefused() {
        var file = MiniPDF()
        file.pageExtras = " /Deep " + String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000)
        assertRefused(file.classic(), because: "objects are nested too deeply")
    }

    func testRangeOfObjectNumbersRunningPastTheFormatLimitIsRefused() {
        // Starts inside the limit and runs past it: only adding the two numbers together reveals it.
        let hostile = MiniPDF.update(MiniPDF().classic(), rawIndexLines: "8388600 100\n")
        assertRefused(hostile, because: "beyond what the format allows")
    }

    func testImpossibleVersionNumberInOldStyleIndexIsRefused() {
        let hostile = MiniPDF.update(MiniPDF().classic(), rawIndexLines: "5 1\n0000000010 70000 n \n")
        assertRefused(hostile, because: "old-style index entry is unreadable")
    }

    func testImpossibleVersionNumberInCompressedIndexIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .impossibleGeneration), because: "impossible version number")
    }

    func testCompressedIndexPointingIntoAnImpossiblePackIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .impossiblePack), because: "impossible object pack")
    }

    func testImpossibleRowWidthIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .hugeColumns), because: "impossible row width")
    }

    func testPackClaimingAbsurdlyManyObjectsIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .absurdPackCount), because: "object pack has an unreadable header")
    }

    /// A pack whose length is stored in a pack could otherwise start a chain with no end.
    func testPackWhoseLengthIsStoredInAPackIsRefused() {
        assertRefused(MiniPDF().compressed(fault: .packLengthInsidePack), because: "not stored as a plain object")
    }

    func testFileWithNoObjectNumbersLeftIsRefused() {
        assertRefused(MiniPDF.update(MiniPDF().classic(), size: "8388606"), because: "no object numbers left")
    }

    func testIndexSectionsThatFormALoopAreRefused() {
        assertRefused(MiniPDF.update(MiniPDF().classic(), previousPointsToItself: true), because: "loop")
    }

    func testPageTreeThatMiscountsItsPagesIsRefused() {
        var file = MiniPDF()
        file.declaredPageCount = 3
        assertRefused(file.classic(), because: "miscounts its pages")
    }

    /// Readers repair a file that lists objects beyond its declared size. An update declaring a
    /// larger size would switch that repair off.
    func testIndexListingObjectsBeyondItsDeclaredSizeIsRefused() {
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        assertRefused(MiniPDF.update(MiniPDF().classic(), objects: [(9, 0, font)], size: "5"), because: "beyond the size it declares")
    }

    func testDecompressionIsCapped() {
        let zeros = MiniPDF.deflate([UInt8](repeating: 0, count: 200_000))
        XCTAssertNil(inflateCompletely(zeros, limit: 1_000), "a small input must not be allowed to expand without bound")
        XCTAssertEqual(inflateCompletely(zeros, limit: 200_000)?.count, 200_000)
    }

    // MARK: The writer's own read-back check

    func testSelfCheckRejectsOutputThatDoesNotStartWithTheOriginal() throws {
        let original = MiniPDF().classic()
        var tampered = try append(to: original)
        tampered[20] ^= 0xFF
        let pages = try PDFStructure(original).pageNumbers()
        XCTAssertThrowsError(try PDFAppendWriter.selfCheck(tampered, original: original, pages: pages, expectedAnnotationCounts: [:])) { error in
            XCTAssertEqual(error as? PDFAppendError, .selfCheckFailed("original bytes were not preserved"))
        }
    }

    func testSelfCheckRejectsAnAnnotationListOfTheWrongLength() throws {
        let original = MiniPDF().classic()
        let result = try append(to: original)
        let pages = try PDFStructure(original).pageNumbers()
        XCTAssertThrowsError(try PDFAppendWriter.selfCheck(result, original: original, pages: pages, expectedAnnotationCounts: [pages[0]: 5])) { error in
            XCTAssertEqual(error as? PDFAppendError, .selfCheckFailed("annotation list is not what was written"))
        }
    }
}
