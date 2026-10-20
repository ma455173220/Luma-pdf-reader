import Foundation

/// Writes a new file holding only what the document still uses: its pages in order, and every
/// object they, the outline, the named destinations and the form lead to, copied byte for byte
/// under new numbers. Pages removed by earlier page edits, and the objects only they used, are left
/// out, which is what makes the copy smaller. The original is not touched.
///
/// Left out besides: the structure information (accessibility tags), which names pages and places on
/// them and cannot be copied page by page; article threads. A file that the append writer would not
/// touch — password, signature, unsound structure — is not copied either.
public enum PDFSlimCopy {

    /// Catalog entries that are not carried into the copy: the page tree is written anew, the rest
    /// belongs to the structure information or to programs that are not readers. A publisher's
    /// usage-rights seal (/Perms) goes too: it is signed over the original's bytes, which the copy
    /// does not have, so Adobe's reader would warn that the document was changed. The form then
    /// no longer says that signatures exist. (A file with any other signature is not copied at all.)
    private static let catalogLeftOut: Set<String> = ["Type", "Pages", "StructTreeRoot", "MarkInfo", "Threads", "Legal", "SpiderInfo", "Version", "Perms"]

    public static func making(from original: Data) throws -> Data {
        let structure = try PDFStructure([UInt8](original))
        if let reason = try structure.refusalReason() { throw PDFAppendError.refused(reason) }
        let pages = try structure.pageNumbers()
        let catalog = try structure.catalog()
        guard let catalogEntries = catalog.entries else { throw PDFAppendError.damaged("document root is missing") }

        // A binary comment in the second line tells programs that the file is not text.
        let header = Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        // 1 is the catalog and 2 the page tree; everything copied is numbered from 3.
        let update = PDFPageWriter.Update(header: header, firstNumber: 3)
        let copier = try PDFPageWriter.PageCopier(structure, mode: .wholeDocument, allocate: { try update.allocate() })
        var finalNumbers: [Int] = []
        for page in pages { finalNumbers.append(try copier.claim(page)) }
        for page in pages {
            let rotation = try PDFAppendWriter.pageRotation(structure.object(page), in: structure)
            try copier.writePage(page, rotation: rotation, parent: "2 0 R", into: update)
        }

        var catalogBody = Array("<< /Type /Catalog /Pages 2 0 R".utf8)
        for entry in catalogEntries where !catalogLeftOut.contains(entry.key) {
            catalogBody.append(32)
            catalogBody.append(contentsOf: entry.rawKey)
            catalogBody.append(32)
            if entry.key == "AcroForm", let form = try structure.resolve(entry.value).entries {
                // Written into the catalog, without the flags that say signatures exist and that the
                // file may only be appended to: both were about the seal, which is not carried over.
                catalogBody.append(contentsOf: Array("<<".utf8))
                for field in form {
                    catalogBody.append(32)
                    catalogBody.append(contentsOf: field.rawKey)
                    catalogBody.append(32)
                    if field.key == "SigFlags" {
                        let flags = try structure.resolve(field.value).int ?? 0
                        catalogBody.append(contentsOf: Array("\(flags & ~3)".utf8))
                    } else {
                        try copier.write(field.value, into: &catalogBody)
                    }
                }
                catalogBody.append(contentsOf: Array(" >>".utf8))
                continue
            }
            try copier.write(entry.value, into: &catalogBody)
        }
        catalogBody.append(contentsOf: Array(" >>".utf8))
        var info: [UInt8]?
        if let value = structure.trailer["Info"] {
            var body: [UInt8] = []
            try copier.write(value, into: &body)
            info = body
        }
        try copier.writePending(into: update)

        try update.begin(1, generation: 0)
        update.out.append(contentsOf: catalogBody)
        update.emit("\nendobj\n")
        try update.begin(2, generation: 0)
        update.emit("<< /Type /Pages /Kids [\(finalNumbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(finalNumbers.count) >>\nendobj\n")

        // One old-style index for every number from 0 up.
        let size = update.nextNumber
        guard size + 1 <= PDFStructure.maximumObjectNumber else { throw PDFAppendError.refused("file has no object numbers left") }
        var offsets = [Int?](repeating: nil, count: size)
        for item in update.written { offsets[item.number] = item.offset }
        let indexOffset = update.out.count
        update.emit("xref\n0 \(size)\n0000000000 65535 f \n")
        for number in 1..<size {
            if let offset = offsets[number] {
                update.emit("\(zeroPadded(offset, 10)) 00000 n \n")
            } else {
                update.emit("0000000000 00000 f \n")
            }
        }
        update.emit("trailer\n<< /Size \(size) /Root 1 0 R")
        if let info {
            update.emit(" /Info ")
            update.out.append(contentsOf: info)
        }
        if let id = structure.trailer["ID"] {
            update.emit(" /ID ")
            update.out.append(contentsOf: id.raw)
        }
        update.emit(" >>\nstartxref\n\(indexOffset)\n%%EOF\n")
        guard update.out.count < PDFStructure.sizeLimit else { throw PDFAppendError.refused("file would grow past 4 GB") }

        try selfCheck(update.out, original: structure, pages: pages, finalNumbers: finalNumbers, copier: copier)
        return Data(update.out)
    }

    private static func zeroPadded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// Reads the copy back with the strict reader: every page in order, showing what it showed, with
    /// all its annotations; every object copied reading back as it was, renumbered.
    static func selfCheck(_ out: [UInt8], original: PDFStructure, pages: [Int], finalNumbers: [Int], copier: PDFPageWriter.PageCopier) throws {
        do {
            let result = try PDFStructure(out)
            guard try result.pageNumbers() == finalNumbers else { throw PDFAppendError.selfCheckFailed("pages are not in order") }
            if let reason = try result.refusalReason() { throw PDFAppendError.selfCheckFailed("result would be refused: \(reason)") }
            for (k, number) in finalNumbers.enumerated() {
                let page = try result.object(number), before = try original.object(pages[k])
                guard try PDFAppendWriter.pageRotation(page, in: result) == PDFAppendWriter.pageRotation(before, in: original) else {
                    throw PDFAppendError.selfCheckFailed("page \(k + 1) is not turned as it was")
                }
                for key in ["Contents", "Resources", "MediaBox", "CropBox", "Annots"] {
                    let was = try PDFPageWriter.inherited(key, from: before, in: original)?.value
                    let now = try PDFPageWriter.inherited(key, from: page, in: result)?.value
                    guard (was == nil) == (now == nil) else { throw PDFAppendError.selfCheckFailed("page \(k + 1) lost \(key)") }
                    if var was, var now {
                        // A list kept as an object of its own may be written straight into the page, or the other way round.
                        if (was.reference == nil) != (now.reference == nil) {
                            was = try original.resolve(was)
                            now = try result.resolve(now)
                        }
                        guard try PDFPageWriter.same(now, was, copier: copier, result: result) else {
                            throw PDFAppendError.selfCheckFailed("page \(k + 1) does not show what it showed (\(key))")
                        }
                    }
                }
            }
            for (old, new) in copier.map where copier.pages[old] == nil {
                guard try PDFPageWriter.same(result.object(new), copier.source.object(old), copier: copier, result: result) else {
                    throw PDFAppendError.selfCheckFailed("a copied object does not read back")
                }
                let a = try result.storedStream(new), b = try copier.source.storedStream(old)
                guard (a == nil) == (b == nil), a.map({ Array($0.data) }) == b.map({ Array($0.data) }) else {
                    throw PDFAppendError.selfCheckFailed("a copied data stream does not read back")
                }
            }
        } catch let error as PDFAppendError {
            if case .selfCheckFailed = error { throw error }
            throw PDFAppendError.selfCheckFailed(error.description)
        }
    }
}
