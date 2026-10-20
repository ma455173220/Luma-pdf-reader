import PDFKit
import XCTest
import LumaCore
@testable import Luma

/// The app's bookkeeping of marks against the real writer: what it hands over on saving, and
/// whether what it keeps afterwards still finds the same marks in the file.
final class MarkupEditorSeamTests: XCTestCase {
    /// A one-page file saying `text` (by default "Hello page one") in 18-point type, laid so that it
    /// shows upright on a page turned by `rotation`, carrying the given annotations (objects 10 onwards).
    private func file(rotation: Int = 0, text: String = "Hello page one", annotations: [String] = []) -> Data {
        let placing = [0: "1 0 0 1 72 700", 90: "0 1 -1 0 300 100", 180: "-1 0 0 -1 500 400", 270: "0 -1 1 0 300 700"][rotation]!
        let stream = "BT /F1 18 Tf \(placing) Tm (\(text)) Tj ET"
        let numbers = annotations.indices.map { 10 + $0 }
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\(rotation == 0 ? "" : " /Rotate \(rotation)") /Contents 4 0 R"
                + " /Resources << /Font << /F1 5 0 R >> >> /Annots [\(numbers.map { "\($0) 0 R" }.joined(separator: " "))] >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        while objects.count < 9 { objects.append("<< >>") }
        objects += annotations
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let start = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(out.utf8)
    }

    private func open(_ data: Data) throws -> DocumentSession {
        DocumentSession(url: URL(fileURLWithPath: "/nonexistent/test.pdf"), document: try XCTUnwrap(PDFDocument(data: data)))
    }

    private func textSelection(_ session: DocumentSession, _ text: String = "Hello") throws -> PDFSelection {
        let page = try XCTUnwrap(session.document.page(at: 0))
        let all = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        return try XCTUnwrap(all.selectionsByLine().first { ($0.string ?? "").contains(text) })
    }

    /// Saves as the app does: the changes go to the writer, and what it reports back to the editor.
    private func save(_ session: DocumentSession, into data: Data) throws -> Data {
        let saving = session.markup.startSaving()
        let (written, rects) = try PDFAppendWriter.applyingReportingRects(saving.changes, to: data)
        session.markup.didSave(saving, newRects: rects)
        XCTAssertFalse(session.markup.hasUnsavedChanges)
        return written
    }

    private func marks(_ session: DocumentSession) -> [PDFAnnotation] {
        session.document.page(at: 0)?.annotations.filter(MarkupEditor.isMark) ?? []
    }

    // MARK: Notes

    func testAStrikethroughGroupedWithACaretIsLeftAsItIs() throws {
        // Acrobat's "replace text": a caret, and a strikethrough replying to it as a group.
        let caret = "<< /Type /Annot /Subtype /Caret /Rect [100 690 110 700] /Contents (new) >>"
        let grouped = "<< /Type /Annot /Subtype /StrikeOut /Rect [72 695 200 715] /QuadPoints [72 715 200 715 72 695 200 695] /C [1 0 0] /IRT 10 0 R /RT /Group >>"
        let alone = "<< /Type /Annot /Subtype /StrikeOut /Rect [72 650 200 670] /QuadPoints [72 670 200 670 72 650 200 650] /C [1 0 0] >>"
        let session = try open(file(annotations: [caret, grouped, alone]))
        let marks = try XCTUnwrap(session.document.page(at: 0)).annotations.filter(MarkupEditor.isMark)
        XCTAssertEqual(marks.count, 2)
        let tied = marks.filter { session.markup.isTiedToAnother($0) }
        XCTAssertEqual(tied.count, 1, "only the grouped one")
        XCTAssertEqual(tied.first?.bounds.minY ?? 0, 695, accuracy: 1)
    }

    func testANoteThatDiffersOnlyBySpacesAroundItIsNotRewritten() throws {
        let original = file(annotations: ["<< /Type /Annot /Subtype /Highlight /Rect [72 696 214 714] /C [1 0.5 0] /Contents (Important\\n) /RC (<p>Important</p>) >>"])
        let session = try open(original)
        let mark = try XCTUnwrap(marks(session).first)
        // The markup panel hands back the note it showed whenever a colour is chosen.
        session.markup.setColour(.red, of: mark)
        session.markup.setNote(mark.contents ?? "", of: mark)
        guard case .modify(_, _, let colour, let note)? = session.markup.changesForSaving().first else { return XCTFail("no change") }
        XCTAssertNotNil(colour)
        XCTAssertEqual(note, .unchanged)
        let saved = try save(session, into: original)
        let list = try XCTUnwrap(PDFDocument(data: saved)?.page(at: 0)?.annotations.first { $0.type == "Highlight" })
        XCTAssertEqual(list.contents, "Important\n", "the note stays exactly as it was")
    }

    func testANoteChangedAndChangedBackIsNotRewritten() throws {
        let original = file(annotations: ["<< /Type /Annot /Subtype /Highlight /Rect [72 696 214 714] /C [1 0.92 0.23] /Contents (Important\\n) /RC (<p>Important</p>) >>"])
        let session = try open(original)
        let mark = try XCTUnwrap(marks(session).first)
        session.markup.setNote("Something else", of: mark)
        session.markup.setNote("Important", of: mark)
        XCTAssertFalse(session.markup.hasUnsavedChanges)
        XCTAssertTrue(session.markup.changesForSaving().isEmpty, "nothing to write: the note in the file stays as it is")
    }

    func testANoteOfOnlySpacesIsNotDeletedByLookingAtIt() throws {
        let session = try open(file(annotations: ["<< /Type /Annot /Subtype /Highlight /Rect [72 696 214 714] /C [1 0.92 0.23] /Contents (   ) >>"]))
        let mark = try XCTUnwrap(marks(session).first)
        session.markup.setNote("", of: mark)
        XCTAssertFalse(session.markup.hasUnsavedChanges)
    }

    // MARK: Colours

    func testChoosingOneOfTheFourColoursChangesAMarkInAnotherColour() throws {
        let session = try open(file(annotations: ["<< /Type /Annot /Subtype /Highlight /Rect [72 696 214 714] /C [1 0.6 0.1] >>"]))
        let mark = try XCTUnwrap(marks(session).first)
        XCTAssertNil(MarkColour.exact(mark.color), "orange is none of the four, so none is ringed")
        session.markup.setColour(.red, of: mark)
        XCTAssertTrue(session.markup.hasUnsavedChanges)
        XCTAssertEqual(MarkColour.exact(mark.color), .red)
    }

    // MARK: Marking the same text again

    func testMarkingTheSameTextWithASavedUnderlineChangesItInsteadOfAddingAnother() throws {
        let original = file()
        let session = try open(original)
        session.markup.mark(try textSelection(session), kind: .underline, colour: .yellow)
        let saved = try save(session, into: original)
        XCTAssertGreaterThan(marks(session)[0].bounds.height, try textSelection(session).bounds(for: session.document.page(at: 0)!).height + 1,
                             "the saved underline's rectangle reaches beyond the text")

        // In the same window after saving, and in the file opened again.
        for session in [session, try open(saved)] {
            session.markup.mark(try textSelection(session), kind: .underline, colour: .blue)
            XCTAssertEqual(marks(session).count, 1, "changed, not laid a second time")
            let again = try PDFAppendWriter.applying(session.markup.changesForSaving(), to: saved)
            XCTAssertEqual(PDFDocument(data: again)?.page(at: 0)?.annotations.filter { $0.type == "Underline" }.count, 1)
        }
    }

    func testMarkingTextThatHasTwoSuchMarksIsCaughtBeforeMarking() throws {
        let plain = try open(file())
        let text = try textSelection(plain).bounds(for: try XCTUnwrap(plain.document.page(at: 0)))
        let twin = "<< /Type /Annot /Subtype /Highlight /Rect [\(text.minX) \(text.minY) \(text.maxX) \(text.maxY)] /C [1 0.92 0.23] >>"
        let session = try open(file(annotations: [twin, twin]))
        XCTAssertTrue(session.markup.meetsMarksThatCannotBeToldApart(try textSelection(session), kind: .highlight))
        XCTAssertFalse(session.markup.meetsMarksThatCannotBeToldApart(try textSelection(session), kind: .underline), "an underline can still go there")
    }

    func testTwoMarksTheFileCannotTellApartAreNotChanged() throws {
        // Both exactly over the text, as two programs might each have marked it.
        let plain = try open(file())
        let text = try textSelection(plain).bounds(for: try XCTUnwrap(plain.document.page(at: 0)))
        let twin = "<< /Type /Annot /Subtype /Highlight /Rect [\(text.minX) \(text.minY) \(text.maxX) \(text.maxY)] /C [1 0.92 0.23] >>"
        let session = try open(file(annotations: [twin, twin]))
        let pair = marks(session)
        XCTAssertEqual(pair.count, 2)
        XCTAssertTrue(pair.allSatisfy(session.markup.cannotBeToldApart))
        session.markup.mark(try textSelection(session), kind: .highlight, colour: .blue)
        XCTAssertFalse(session.markup.hasUnsavedChanges, "marking the text again leaves the pair as it is")
    }

    // MARK: Turned pages

    func testAnUnderlineSavedOnATurnedPageCanBeChangedAndRemovedInTheSameWindow() throws {
        for rotation in [90, 180, 270] {
            let original = file(rotation: rotation)
            let session = try open(original)
            session.markup.mark(try textSelection(session), kind: .underline, colour: .yellow, note: "附注")
            let saved = try save(session, into: original)
            let mark = try XCTUnwrap(marks(session).first)
            session.markup.setColour(.blue, of: mark)
            let recoloured = try save(session, into: saved)
            session.markup.delete(mark)
            let removed = try save(session, into: recoloured)
            XCTAssertEqual(PDFDocument(data: removed)?.page(at: 0)?.annotations.filter(MarkupEditor.isMark).count, 0, "rotation \(rotation)")
        }
    }

    func testAnUnderlinedShortWordOnATurnedPageCanBeChangedAfterSaving() throws {
        // A short word, where the rectangle the app would work out for itself and the one written
        // differ by more than marks are matched by.
        for rotation in [90, 270] {
            let original = file(rotation: rotation, text: "Il")
            let session = try open(original)
            session.markup.mark(try textSelection(session, "Il"), kind: .underline, colour: .yellow)
            let saved = try save(session, into: original)
            session.markup.setColour(.blue, of: try XCTUnwrap(marks(session).first))
            XCTAssertNoThrow(try save(session, into: saved), "rotation \(rotation)")
        }
    }

    // MARK: A change the file will not take

    func testAChangeTheFileWillNotTakeCanBeDroppedAndTheRestSaved() throws {
        let original = file(annotations: ["<< /Type /Annot /Subtype /Highlight /Rect [72 696 214 714] /C [1 0.92 0.23] >>",
                                          "<< /Type /Annot /Subtype /Text /Rect [300 600 320 620] /IRT 10 0 R /Contents (a reply) >>"])
        let session = try open(original)
        let highlight = try XCTUnwrap(marks(session).first)
        session.markup.delete(highlight)
        session.markup.mark(try textSelection(session), kind: .underline, colour: .green)
        let saving = session.markup.startSaving()
        var refused: Int?
        XCTAssertThrowsError(try PDFAppendWriter.applyingReportingRects(saving.changes, to: original)) { error in
            if case PDFAppendError.refusedChange(let position, _) = error { refused = position }
        }
        let position = try XCTUnwrap(refused, "the writer says which change it will not make")
        guard case .remove = saving.changes[position] else { return XCTFail("the removal is the one refused") }

        session.markup.discard(changeAt: position, of: saving)
        XCTAssertTrue(highlight.page != nil, "the highlight is back on its page")
        XCTAssertTrue(session.markup.hasUnsavedChanges, "the underline is still to be saved")
        let saved = try save(session, into: original)
        let annotations = PDFDocument(data: saved)?.page(at: 0)?.annotations ?? []
        XCTAssertTrue(annotations.contains { $0.type == "Highlight" })
        XCTAssertTrue(annotations.contains { $0.type == "Underline" })
    }

    // MARK: Reloading

    /// A file with a highlight the reader saved earlier over "Hello page one".
    private func fileWithSavedHighlight() throws -> Data {
        let original = file()
        let session = try open(original)
        session.markup.mark(try textSelection(session), kind: .highlight, colour: .yellow)
        return try save(session, into: original)
    }

    func testDeletingAMarkAndMarkingTheSameTextAgainSurvivesReloading() throws {
        let saved = try fileWithSavedHighlight()
        let old = try open(saved)
        old.markup.delete(try XCTUnwrap(marks(old).first))
        old.markup.mark(try textSelection(old), kind: .highlight, colour: .blue)
        let changes = old.markup.changesForSaving()

        let fresh = try open(saved)
        XCTAssertTrue(fresh.markup.reapply(changes, from: old.document, onlyCheck: true).isEmpty)
        XCTAssertTrue(fresh.markup.reapply(changes, from: old.document).isEmpty)
        XCTAssertEqual(marks(fresh).count, 1)
        XCTAssertEqual(MarkColour.exact(marks(fresh)[0].color), .blue, "the old one went, the new one stayed")
        let result = try PDFAppendWriter.applying(fresh.markup.changesForSaving(), to: saved)
        let highlights = PDFDocument(data: result)?.page(at: 0)?.annotations.filter { $0.type == "Highlight" } ?? []
        XCTAssertEqual(highlights.count, 1)
        XCTAssertEqual(highlights.first.flatMap { MarkColour.exact($0.color) }, .blue)
    }

    func testANewMarkIsNotTakenForTheOneAnotherProgramAlreadyRemoved() throws {
        let saved = try fileWithSavedHighlight()
        let old = try open(saved)
        let first = try XCTUnwrap(marks(old).first)
        old.markup.delete(first)
        old.markup.mark(try textSelection(old), kind: .highlight, colour: .blue)
        let changes = old.markup.changesForSaving()
        // Meanwhile another program removed the old highlight from the file.
        let elsewhere = try PDFAppendWriter.applying([.remove(page: 0, original: ExistingMarkup(kind: .highlight, rect: first.bounds))], to: saved)

        let fresh = try open(elsewhere)
        let checked = fresh.markup.reapply(changes, from: old.document, onlyCheck: true)
        let missed = fresh.markup.reapply(changes, from: old.document)
        XCTAssertEqual(checked.count, 1, "the removal has nothing left to remove")
        XCTAssertEqual(missed.count, checked.count, "putting back does what the check said")
        XCTAssertEqual(marks(fresh).count, 1, "the reader's new mark is still there")
        let result = try PDFAppendWriter.applying(fresh.markup.changesForSaving(), to: elsewhere)
        XCTAssertEqual(PDFDocument(data: result)?.page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count, 1)
    }

    func testPuttingChangesBackCanBeUndone() throws {
        let saved = try fileWithSavedHighlight()
        let old = try open(saved)
        let first = try XCTUnwrap(marks(old).first)
        old.markup.setColour(.red, of: first)
        old.markup.mark(try textSelection(old), kind: .underline, colour: .green)
        let fresh = try open(saved)
        fresh.markup.reapply(old.markup.changesForSaving(), from: old.document)
        XCTAssertTrue(fresh.markup.hasUnsavedChanges)
        XCTAssertEqual(marks(fresh).count, 2)
        fresh.markup.undoManager.undo()
        XCTAssertFalse(fresh.markup.hasUnsavedChanges)
        XCTAssertEqual(marks(fresh).count, 1)
        XCTAssertEqual(MarkColour.exact(marks(fresh)[0].color), .yellow)
        fresh.markup.undoManager.redo()
        XCTAssertTrue(fresh.markup.hasUnsavedChanges)
        XCTAssertEqual(marks(fresh).count, 2)
    }
}
