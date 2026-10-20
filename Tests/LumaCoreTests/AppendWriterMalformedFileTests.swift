import XCTest
@testable import LumaCore

/// Files that are simply malformed. Each case spoils one thing in an otherwise sound file and names
/// the reason the writer must give for turning it away, so that every check has something watching it.
final class AppendWriterMalformedFileTests: XCTestCase {
    private func mark() -> MarkupAddition {
        MarkupAddition(pageIndex: 0, lineRects: [CGRect(x: 72, y: 696, width: 140, height: 20)], red: 1, green: 0.92, blue: 0.23)
    }

    /// The file as text, one character per byte, so that binary parts survive a text replacement.
    private func latin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
    }

    private func reason(_ bytes: [UInt8]) -> String {
        do {
            _ = try PDFAppendWriter.appending([mark()], to: Data(bytes))
            return "(accepted)"
        } catch {
            return "\(error)"
        }
    }

    /// Replaces text with text of the same length, so that every position recorded in the file stays true.
    /// `last` spoils the final occurrence, which in these files is the one in the trailer or the index.
    private func spoil(_ bytes: [UInt8], _ old: String, _ new: String, last: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
        XCTAssertEqual(old.utf8.count, new.utf8.count, "replacement must keep the length", file: file, line: line)
        let text = latin1(bytes)
        guard let range = last ? text.range(of: old, options: .backwards) : text.range(of: old) else {
            XCTFail("\"\(old)\" is not in the file", file: file, line: line)
            return bytes
        }
        return Array(text.replacingCharacters(in: range, with: new).unicodeScalars.map { UInt8($0.value) })
    }

    /// Makes the object pack claim to be five bytes shorter than it is, keeping the digit count.
    private func withPackLengthReduced(_ bytes: [UInt8]) -> [UInt8] {
        let text = latin1(bytes)
        let pack = text.range(of: "/Type /ObjStm")!
        let label = text.range(of: "/Length ", range: pack.upperBound..<text.endIndex)!
        let digits = text[label.upperBound...].prefix { $0.isNumber }
        let shorter = MiniPDF.padded(Int(digits)! - 5, digits.count)
        return spoil(bytes, "/Length \(digits) >>\nstream", "/Length \(shorter) >>\nstream")
    }

    private func position(of text: String, in bytes: [UInt8]) -> Int {
        let whole = latin1(bytes)
        return whole.distance(from: whole.startIndex, to: whole.range(of: text)!.lowerBound)
    }

    func testSpoiledOldStyleFiles() {
        let sound = MiniPDF().classic()
        XCTAssertEqual(reason(sound), "(accepted)", "the starting point must itself be sound")
        let cases: [(String, [UInt8], String)] = [
            ("no pointer to the index", spoil(sound, "startxref", "startxrex"), "file has no pointer to its index"),
            ("trailer is a list", spoil(spoil(sound, "trailer\n<<", "trailer\n[ "), ">>\nstartxref", " ]\nstartxref"), "trailer is not a dictionary"),
            ("trailer names no root", spoil(sound, "/Root 1 0 R", "/Rood 1 0 R", last: true), "trailer does not name the document root"),
            ("root is an empty slot", spoil(sound, "/Root 1 0 R", "/Root 8 0 R", last: true), "document root is missing"),
            ("root names no page tree", spoil(sound, "/Pages 2 0 R", "/Pagez 2 0 R"), "document has no page tree"),
            ("index entry is neither n nor f", spoil(sound, " 00000 n \n", " 00000 x \n"), "neither in use nor free"),
            ("children are text, not a list", spoil(sound, "/Kids [3 0 R 4 0 R]", "/Kids (3 0 R 4 0 R)"), "page tree children are not a list"),
            ("a child is a number", spoil(sound, "/Kids [3 0 R 4 0 R]", "/Kids [3 0 R 44444]"), "page tree child is not a reference"),
            ("a child is an empty slot", spoil(sound, "/Kids [3 0 R 4 0 R]", "/Kids [3 0 R 8 0 R]"), "page tree refers to something that is not there"),
            ("a leaf is not a page", spoil(sound, "/Type /Page /Parent", "/Type /Pago /Parent"), "page tree ends in something that is not a page"),
        ]
        for (name, bytes, expected) in cases {
            XCTAssertTrue(reason(bytes).contains(expected), "\(name): got \"\(reason(bytes))\", expected \"\(expected)\"")
        }
    }

    func testIndexPointerLeadingToTheWrongKindOfThing() {
        let sound = MiniPDF().classic()
        let text = latin1(sound)
        let pointer = text.components(separatedBy: "startxref\n").last!.components(separatedBy: "\n").first!
        func pointing(at target: Int) -> [UInt8] {
            spoil(sound, "startxref\n\(pointer)", "startxref\n" + MiniPDF.padded(target, pointer.count), last: true)
        }
        // At a number that is not the start of an object.
        XCTAssertTrue(reason(pointing(at: position(of: "612 792]", in: sound))).contains("expected an object"))
        // At an object that is not a data stream.
        XCTAssertTrue(reason(pointing(at: position(of: "7 0 obj", in: sound))).contains("expected a data stream"))
        // At something that is neither blank nor a number.
        XCTAssertTrue(reason(pointing(at: 3)).contains("does not lead to an index"))
        // Not a number at all.
        XCTAssertTrue(reason(spoil(sound, "startxref\n\(pointer)", "startxref\n" + String(repeating: "x", count: pointer.count), last: true))
            .contains("pointer to the index is unreadable"))
    }

    func testSpoiledUpdateSections() {
        let sound = MiniPDF().classic()
        let basePointer = latin1(sound).components(separatedBy: "startxref\n").last!.components(separatedBy: "\n").first!
        let cases: [(String, [UInt8], String)] = [
            ("entry pointing into the file header", MiniPDF.update(sound, rawIndexLines: "5 1\n0000000003 00000 n \n"), "index points at the wrong place"),
            ("table claiming more entries than the file could hold", MiniPDF.update(sound, rawIndexLines: "5 8000000\n"), "longer than the file"),
            ("hybrid pointer that is text", MiniPDF.update(sound, trailerExtras: " /XRefStm (oops)"), "hybrid index pointer is unusable"),
            ("hybrid pointer leading to an old-style table", MiniPDF.update(sound, trailerExtras: " /XRefStm \(basePointer)"), "does not lead to a compressed index"),
            ("compressed half with an odd range list",
             spoil(MiniPDF.update(sound, freedInCompressedPart: [12]), "/Index [12 1 20 1]", "/Index [12 1 20  ]"), "unreadable range list"),
        ]
        for (name, bytes, expected) in cases {
            XCTAssertTrue(reason(bytes).contains(expected), "\(name): got \"\(reason(bytes))\", expected \"\(expected)\"")
        }
    }

    func testSpoiledCompressedFiles() {
        let sound = MiniPDF().compressed()
        XCTAssertEqual(reason(sound), "(accepted)", "the starting point must itself be sound")
        let predicted = MiniPDF().compressed(usePredictor: true)
        let cases: [(String, [UInt8], String)] = [
            ("index without field widths", spoil(sound, "/W [1 4 2]", "/X [1 4 2]"), "does not say how wide its fields are"),
            ("index compressed another way", spoil(sound, "/Filter /FlateDecode", "/Filter /LZWDecode  ", last: true), "compression method this writer does not handle"),
            ("index naming its compression as text", spoil(sound, "/Filter /FlateDecode", "/Filter (FlateDecod)", last: true), "names its compression in an unreadable way"),
            ("index with a predictor of another kind", spoil(predicted, "/Predictor 12", "/Predictor  2"), "compression setting this writer does not handle"),
            ("pack that is shorter than it says", withPackLengthReduced(sound), "data stream does not end where it says"),
            ("pack that is itself inside a pack", MiniPDF().compressed(fault: .packIsNotAPlainObject), "object pack is missing from the index"),
            ("pack listing fewer objects than it claims", MiniPDF().compressed(fault: .packTableTooShort), "unreadable table of contents"),
        ]
        for (name, bytes, expected) in cases {
            XCTAssertTrue(reason(bytes).contains(expected), "\(name): got \"\(reason(bytes))\", expected \"\(expected)\"")
        }
    }

    func testMalformedObjectsAreNamedForWhatIsWrong() {
        func failure(_ text: String) -> String {
            var parser = PDFParser(Array(text.utf8), at: 0)
            do {
                _ = try parser.value()
                return "(parsed)"
            } catch {
                return "\(error)"
            }
        }
        XCTAssertTrue(failure("").contains("data ends in the middle of an object"))
        XCTAssertTrue(failure("<< /A 1").contains("dictionary never closes"))
        XCTAssertTrue(failure("<< 1 2 >>").contains("dictionary key is not a name"))
        XCTAssertTrue(failure("[1 2").contains("list never closes"))
        XCTAssertTrue(failure("(never ends").contains("text string never closes"))
        XCTAssertTrue(failure("<4142").contains("hex string never closes"))
        XCTAssertTrue(failure(")").contains("unexpected character in an object"))
        XCTAssertTrue(failure("@@").contains("unrecognised word in an object"))
        XCTAssertEqual(failure("<< /A [1 (two) <33> /Four 5 0 R true null 6.5] >>"), "(parsed)")
    }

    func testFormWithTooManyFieldsToCheckIsRefused() {
        var file = MiniPDF()
        let numbers = Array(100..<20_150)
        file.catalogExtras = " /AcroForm << /Fields [\(numbers.map { "\($0) 0 R" }.joined(separator: " "))] >>"
        file.extraObjects = numbers.map { ($0, 0, "<< /T (f) >>") }
        XCTAssertTrue(reason(file.classic()).contains("too many fields"))
    }

    func testMarkWithoutAnyAreaIsRefused() {
        let empty = MarkupAddition(pageIndex: 0, lineRects: [], red: 1, green: 1, blue: 0)
        XCTAssertThrowsError(try PDFAppendWriter.appending([empty], to: Data(MiniPDF().classic()))) { error in
            XCTAssertEqual(error as? PDFAppendError, .refusedChange(0, "the annotation has no usable area"))
        }
        let infinite = MarkupAddition(pageIndex: 0, lineRects: [CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)], red: 1, green: 1, blue: 0)
        XCTAssertThrowsError(try PDFAppendWriter.appending([infinite], to: Data(MiniPDF().classic())))
    }

    func testSelfCheckNoticesIfThePagesAreNotTheOnesItStartedWith() throws {
        let original = MiniPDF().classic()
        let result = [UInt8](try PDFAppendWriter.appending([mark()], to: Data(original)))
        XCTAssertThrowsError(try PDFAppendWriter.selfCheck(result, original: original, pages: [999], expectedAnnotationCounts: [:])) { error in
            XCTAssertEqual(error as? PDFAppendError, .selfCheckFailed("pages changed"))
        }
    }
}
