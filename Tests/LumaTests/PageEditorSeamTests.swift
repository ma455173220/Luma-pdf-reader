import PDFKit
import XCTest
import LumaCore
@testable import Luma

/// The app's page edits against the real writers: what the window shows after each edit, what
/// saving hands over, and what the saved file then holds.
final class PageEditorSeamTests: XCTestCase {
    /// A file of pages saying "<prefix> 1", "<prefix> 2"…, each carrying the given annotations.
    private func file(pages: Int, prefix: String = "Page", annotations: [String] = []) -> Data {
        var objects: [String] = []
        // 1 catalog, 2 page tree, 3 font, then per page: the page, its contents, its annotations.
        var kids: [Int] = []
        var bodies: [Int: String] = [1: "<< /Type /Catalog /Pages 2 0 R >>", 3: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        var next = 4
        for k in 0..<pages {
            let page = next, contents = next + 1
            next += 2
            var annots: [Int] = []
            for body in annotations {
                annots.append(next)
                bodies[next] = body
                next += 1
            }
            let stream = "BT /F1 18 Tf 72 700 Td (\(prefix) \(k + 1)) Tj ET"
            bodies[page] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contents) 0 R /Resources << /Font << /F1 3 0 R >> >>"
                + (annots.isEmpty ? "" : " /Annots [\(annots.map { "\($0) 0 R" }.joined(separator: " "))]") + " >>"
            bodies[contents] = "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
            kids.append(page)
        }
        bodies[2] = "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages) >>"
        for number in 1..<next { objects.append(bodies[number] ?? "<< >>") }
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

    private func source(_ data: Data) throws -> PageEditor.Source {
        PageEditor.Source(url: URL(fileURLWithPath: "/nonexistent/other.pdf"), data: data, document: try XCTUnwrap(PDFDocument(data: data)))
    }

    private func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Saves as the app does: page edits first, then the marks, by the page numbers they have now.
    private func save(_ session: DocumentSession, into data: Data) throws -> Data {
        let saving = session.markup.startSaving()
        let pages = session.pages.forSaving
        let arranged = try pages.map { try PDFPageWriter.applying($0.slots, sources: $0.sources, to: data) } ?? data
        let (written, rects) = try PDFAppendWriter.applyingReportingRects(saving.changes, to: arranged)
        session.markup.didSave(saving, newRects: rects)
        return written
    }

    func testEditsShowAtOnceAndSaveAsShown() throws {
        let original = file(pages: 3)
        let session = try open(original)
        session.pages.turn(0, clockwise: true)
        session.pages.takeOut(1)
        session.pages.move(1, toGap: 0)
        try session.pages.insert(source(file(pages: 2, prefix: "Other")), atGap: 2)
        XCTAssertEqual(texts(session.document), ["Page 3", "Page 1", "Other 1", "Other 2"])
        XCTAssertEqual(session.document.page(at: 1)?.rotation, 90)
        XCTAssertEqual(session.pageSizes[1], CGSize(width: 792, height: 612), "a turned page is laid out turned")
        XCTAssertTrue(session.hasUnsavedChanges)

        let saved = try save(session, into: original)
        XCTAssertEqual(Array(saved.prefix(original.count)), Array(original))
        let back = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(texts(back), ["Page 3", "Page 1", "Other 1", "Other 2"])
        XCTAssertEqual((0..<4).map { back.page(at: $0)?.rotation }, [0, 90, 0, 0])
    }

    func testEverythingCanBeUndoneAndRedone() throws {
        let session = try open(file(pages: 3))
        let undo = session.markup.undoManager
        undo.groupsByEvent = false
        for edit in [{ session.pages.turn(2, clockwise: false) }, { session.pages.takeOut(0) }, { session.pages.move(0, toGap: 2) }] {
            undo.beginUndoGrouping()
            edit()
            undo.endUndoGrouping()
        }
        undo.beginUndoGrouping()
        try session.pages.insert(source(file(pages: 1, prefix: "Other")), atGap: 0)
        undo.endUndoGrouping()
        let edited = texts(session.document)
        XCTAssertEqual(edited, ["Other 1", "Page 3", "Page 2"])
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(texts(session.document), ["Page 1", "Page 2", "Page 3"])
        XCTAssertEqual(session.document.page(at: 2)?.rotation, 0)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertNil(session.pages.forSaving)
        while undo.canRedo { undo.redo() }
        XCTAssertEqual(texts(session.document), edited)
        XCTAssertEqual(session.document.page(at: 1)?.rotation, 270)
    }

    func testAMarkOnAPageTakenOutIsNotSaved() throws {
        let original = file(pages: 2)
        let session = try open(original)
        let page = try XCTUnwrap(session.document.page(at: 1))
        let line = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine().first)
        session.markup.mark(line, kind: .highlight, colour: .yellow)
        XCTAssertTrue(session.markup.hasUnsavedChanges)
        session.pages.takeOut(1)
        XCTAssertFalse(session.markup.hasUnsavedChanges, "the mark went with its page")
        XCTAssertTrue(session.markup.changesForSaving().isEmpty)
        let back = try XCTUnwrap(PDFDocument(data: try save(session, into: original)))
        XCTAssertEqual(texts(back), ["Page 1"])
        XCTAssertTrue(back.page(at: 0)?.annotations.isEmpty ?? false)
    }

    func testMarksFollowTheirPageWhenPagesMove() throws {
        let original = file(pages: 3)
        let session = try open(original)
        let page = try XCTUnwrap(session.document.page(at: 2))
        let line = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine().first)
        session.markup.mark(line, kind: .underline, colour: .blue)
        session.pages.move(2, toGap: 0)
        session.pages.turn(0, clockwise: true)
        let back = try XCTUnwrap(PDFDocument(data: try save(session, into: original)))
        XCTAssertEqual(texts(back), ["Page 3", "Page 1", "Page 2"])
        XCTAssertEqual(back.page(at: 0)?.annotations.filter { $0.type == "Underline" }.count, 1)
        XCTAssertEqual(back.page(at: 0)?.rotation, 90)
    }

    func testAMarkOnAnInsertedPageCanBeChangedBeforeSaving() throws {
        let original = file(pages: 1)
        let other = file(pages: 1, prefix: "Other", annotations: ["<< /Type /Annot /Subtype /Highlight /Rect [72 696 160 718] /C [1 1 0] >>"])
        let session = try open(original)
        try session.pages.insert(source(other), atGap: 1)
        let mark = try XCTUnwrap(session.document.page(at: 1)?.annotations.first(where: MarkupEditor.isMark))
        session.markup.setColour(.green, of: mark)
        let back = try XCTUnwrap(PDFDocument(data: try save(session, into: original)))
        let saved = try XCTUnwrap(back.page(at: 1)?.annotations.first { $0.type == "Highlight" })
        let colour = try XCTUnwrap(saved.color.usingColorSpace(.sRGB))
        XCTAssertEqual(colour.greenComponent, 0.85, accuracy: 0.01)
        XCTAssertEqual(back.page(at: 1)?.annotations.filter { $0.type == "Highlight" }.count, 1)
    }

    func testAfterSavingNothingIsWrittenTwice() throws {
        let original = file(pages: 3)
        let session = try open(original)
        try session.pages.insert(source(file(pages: 1, prefix: "Other")), atGap: 1)
        session.pages.move(3, toGap: 0)
        let saved = try save(session, into: original)
        // What every save path does once the file is written, whether or not it is then read again.
        session.pages.didSave()
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertNil(session.pages.forSaving, "a second save has no page edits to write")
        XCTAssertTrue(session.pages.sources.isEmpty, "the document inserted from is let go")
        // Edits made after that are measured from the saved file.
        session.pages.turn(0, clockwise: true)
        let again = try save(session, into: saved)
        XCTAssertEqual(texts(try XCTUnwrap(PDFDocument(data: again))), ["Page 3", "Page 1", "Other 1", "Page 2"])
        XCTAssertEqual(PDFDocument(data: again)?.page(at: 0)?.rotation, 90)
    }

    func testMarksGoBackOnTheirPagesWhenTheFileIsReadAgain() throws {
        let original = file(pages: 3)
        let session = try open(original)
        let page = try XCTUnwrap(session.document.page(at: 2))
        let line = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine().first)
        session.markup.mark(line, kind: .highlight, colour: .yellow)
        session.pages.move(2, toGap: 0)
        try session.pages.insert(source(file(pages: 1, prefix: "Other")), atGap: 0)
        let inserted = try XCTUnwrap(session.document.page(at: 0))
        let otherLine = try XCTUnwrap(inserted.selection(for: inserted.bounds(for: .mediaBox))?.selectionsByLine().first)
        session.markup.mark(otherLine, kind: .underline, colour: .red)
        // The page edits are given up; the file is read again as it is.
        let fresh = try open(original)
        let (changes, pageMadeOn, onInserted) = session.pages.toFilePages(session.markup.changesForSaving())
        XCTAssertEqual(onInserted, 1, "the mark on the inserted page has nowhere to go")
        XCTAssertTrue(fresh.markup.reapply(changes, from: { pageMadeOn[$0] }).isEmpty)
        XCTAssertEqual(fresh.document.page(at: 2)?.annotations.filter { $0.type == "Highlight" }.count, 1, "back on Page 3")
        XCTAssertEqual(fresh.document.page(at: 0)?.annotations.filter(MarkupEditor.isMark).count, 0)
    }

    func testLinksAreWorkedOutAgainWhenPagesWereEditedWhileTheyWereBeing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("luma-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("paper.pdf")
        try file(pages: 3).write(to: path)
        let session = DocumentSession(url: path, document: try XCTUnwrap(PDFDocument(url: path)))
        _ = session.links(onPage: 0)
        XCTAssertEqual(session.debugDecoding, "preparing")
        session.pages.takeOut(1)
        let deadline = Date(timeIntervalSinceNow: 10)
        while session.debugDecoding == "preparing" && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        XCTAssertEqual(session.debugDecoding, "not started", "left to be tried again, not given up for good")
    }

    func testSaveAsWritesWhatIsShownAndLeavesTheOriginalAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("luma-saveas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("paper.pdf")
        let original = file(pages: 3)
        try original.write(to: path)
        let session = DocumentSession(url: path, document: try XCTUnwrap(PDFDocument(url: path)))
        let page = try XCTUnwrap(session.document.page(at: 2))
        let line = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine().first)
        session.markup.mark(line, kind: .highlight, colour: .yellow)
        session.pages.takeOut(0)
        session.pages.turn(0, clockwise: true)
        try session.pages.insert(source(file(pages: 1, prefix: "Other")), atGap: 2)
        let target = folder.appendingPathComponent("paper 副本.pdf")
        try ReaderWindowController.writeSaveAs(session.markup.startSaving().changes, pages: session.pages.forSaving, from: path,
                                               expecting: DocumentSession.FileStamp.of(path), to: target, pageCount: session.document.pageCount)
        XCTAssertEqual(try Data(contentsOf: path), original, "the original is not touched")
        let saved = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(texts(saved), ["Page 2", "Page 3", "Other 1"])
        XCTAssertEqual(saved.page(at: 0)?.rotation, 90)
        XCTAssertEqual(saved.page(at: 1)?.annotations.filter { $0.type == "Highlight" }.count, 1)
        let bytes = String(decoding: try Data(contentsOf: target), as: UTF8.self)
        XCTAssertFalse(bytes.contains("Page 1"), "the page taken out is not in the new file at all")
    }

    func testOnlyATabWithNothingToLoseMaySleep() throws {
        let session = try open(file(pages: 2))
        XCTAssertTrue(session.maySleep)
        session.markup.undoManager.groupsByEvent = false
        session.markup.undoManager.beginUndoGrouping()
        session.pages.turn(0, clockwise: true)
        session.markup.undoManager.endUndoGrouping()
        XCTAssertFalse(session.maySleep, "an unsaved page edit")
        session.markup.undoManager.undo()
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertFalse(session.maySleep, "a step that could be redone")
        session.markup.undoManager.removeAllActions()
        XCTAssertTrue(session.maySleep)

        session.scale = 1.7
        session.fitsWidth = false
        session.position = PageLayout.Anchor(page: 1, x: 0.2, y: 0.4)
        session.history.jumped(from: PageLayout.Anchor(page: 0))
        let sleeping = session.asleep()
        XCTAssertTrue(sleeping.isAsleep)
        XCTAssertEqual(sleeping.document.pageCount, 0, "the document is let go")
        XCTAssertFalse(sleeping.maySleep)
        XCTAssertEqual(sleeping.scale, 1.7)
        XCTAssertFalse(sleeping.fitsWidth)
        XCTAssertEqual(sleeping.position, PageLayout.Anchor(page: 1, x: 0.2, y: 0.4))
        XCTAssertTrue(sleeping.history.canGoBack)
        // Waking: a fresh reading of the file takes the place over.
        let awake = try open(file(pages: 2))
        sleeping.carry(to: awake)
        XCTAssertEqual(awake.position, PageLayout.Anchor(page: 1, x: 0.2, y: 0.4))
        XCTAssertTrue(awake.history.canGoBack)
        // A file changed meanwhile, now with one page: the place is kept within it, the way back is not.
        let changed = try open(file(pages: 1))
        sleeping.carry(to: changed, fileChanged: true)
        XCTAssertEqual(changed.position?.page, 0)
        XCTAssertFalse(changed.history.canGoBack)
    }

    func testAJournalPDFWithOnlyAnOwnerPasswordMaySleep() throws {
        // Many journal PDFs carry a password only to restrict printing or copying: they open without asking.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("luma-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("restricted.pdf")
        let plain = try XCTUnwrap(PDFDocument(data: file(pages: 2)))
        XCTAssertTrue(plain.write(to: path, withOptions: [.ownerPasswordOption: "publisher"]))
        let document = try XCTUnwrap(PDFDocument(url: path))
        XCTAssertTrue(document.isEncrypted)
        XCTAssertFalse(document.isLocked, "it opens without asking")
        let session = DocumentSession(url: path, document: document)
        XCTAssertTrue(session.maySleep)
        // One that asked for a password on opening never sleeps.
        session.neededPassword = true
        XCTAssertFalse(session.maySleep)
    }

    func testTheLastPageCannotBeTakenOut() throws {
        let session = try open(file(pages: 1))
        session.pages.takeOut(0)
        XCTAssertEqual(session.document.pageCount, 1)
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testInsertingFromTheSameFileTwice() throws {
        let original = file(pages: 2)
        let session = try open(original)
        try session.pages.insert(source(original), atGap: 2)
        try session.pages.insert(source(original), atGap: 0)
        let back = try XCTUnwrap(PDFDocument(data: try save(session, into: original)))
        XCTAssertEqual(texts(back), ["Page 1", "Page 2", "Page 1", "Page 2", "Page 1", "Page 2"])
    }
}
