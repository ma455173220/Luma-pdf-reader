import PDFKit
import XCTest
@testable import Luma

/// A slim copy must never be written over the original, however the path to it is spelled.
final class SameFileTests: XCTestCase {
    func testTheOriginalIsRecognisedByAnyPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("luma-same-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: original)
        let other = folder.appendingPathComponent("other.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: other)
        let hard = folder.appendingPathComponent("hard.pdf")
        try FileManager.default.linkItem(at: original, to: hard)
        let soft = folder.appendingPathComponent("soft.pdf")
        try FileManager.default.createSymbolicLink(at: soft, withDestinationURL: original)

        XCTAssertTrue(ReaderWindowController.isSameFile(original, original))
        XCTAssertTrue(ReaderWindowController.isSameFile(hard, original), "a hard link")
        XCTAssertTrue(ReaderWindowController.isSameFile(soft, original), "a symbolic link")
        // On a disk that ignores letter case (the Mac's usual one) this is the same file too.
        let upper = folder.appendingPathComponent("PAPER.pdf")
        if FileManager.default.fileExists(atPath: upper.path) {
            XCTAssertTrue(ReaderWindowController.isSameFile(upper, original), "the same name in other letter case")
        }
        XCTAssertFalse(ReaderWindowController.isSameFile(other, original))
        XCTAssertFalse(ReaderWindowController.isSameFile(folder.appendingPathComponent("new.pdf"), original), "a file not there yet")
    }
}

final class SlimCopyRoutingTests: XCTestCase {
    func testTheCopyIsOfTheDocumentAskedForWhicheverTabIsInFront() throws {
        func session(_ path: String) throws -> DocumentSession {
            let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
            return DocumentSession(url: URL(fileURLWithPath: path), document: try XCTUnwrap(PDFDocument(data: data)))
        }
        let asked = try session("/tmp/a.pdf"), other = try session("/tmp/b.pdf"), readAgain = try session("/tmp/a.pdf")
        XCTAssertTrue(ReaderWindowController.sameDocument(as: asked, among: [other, asked]) === asked)
        XCTAssertTrue(ReaderWindowController.sameDocument(as: asked, among: [other, readAgain]) === readAgain, "saving page edits replaced it")
        XCTAssertNil(ReaderWindowController.sameDocument(as: asked, among: [other]), "its tab was closed")
    }
}

final class InsertReportTests: XCTestCase {
    func testTheReaderIsToldWhichFilesWentInAndWhichDidNot() throws {
        XCTAssertNil(ReaderWindowController.insertReport(inserted: ["a.pdf", "b.pdf"], failed: []))
        let one = try XCTUnwrap(ReaderWindowController.insertReport(inserted: [], failed: [("a.pdf", "它有密码。")]))
        XCTAssertEqual(one.0, "Can’t insert “a.pdf”")
        let some = try XCTUnwrap(ReaderWindowController.insertReport(inserted: ["a.pdf", "c.pdf"], failed: [("b.pdf", "它有密码。")]))
        XCTAssertEqual(some.0, "Files not inserted: 1")
        XCTAssertTrue(some.1.contains("“b.pdf”: 它有密码。"))
        XCTAssertTrue(some.1.contains("Inserted: “a.pdf”, “c.pdf”."))
    }
}

final class SaveAsTargetTests: XCTestCase {
    func testAFileOpenInAnotherTabIsNotATarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("luma-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
        let a = folder.appendingPathComponent("a.pdf"), b = folder.appendingPathComponent("b.pdf")
        try data.write(to: a)
        try data.write(to: b)
        let first = DocumentSession(url: a, document: try XCTUnwrap(PDFDocument(url: a)))
        let second = DocumentSession(url: b, document: try XCTUnwrap(PDFDocument(url: b)))
        XCTAssertTrue(ReaderWindowController.openElsewhere(b, among: [first, second], besides: first) === second)
        XCTAssertNil(ReaderWindowController.openElsewhere(folder.appendingPathComponent("c.pdf"), among: [first, second], besides: first))
        XCTAssertNil(ReaderWindowController.openElsewhere(a, among: [first, second], besides: first), "its own file is checked separately")
    }
}
