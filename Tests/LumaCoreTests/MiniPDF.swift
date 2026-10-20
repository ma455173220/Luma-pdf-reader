import Foundation
import zlib

/// Builds tiny two-page PDFs by hand so that each awkward file shape can be tested on purpose.
/// Page 1 says "Hello page one" and carries one existing note; page 2 says "Hello page two".
///
/// Object numbers: 1 catalog, 2 page tree, 3 page one, 4 page two, 5 and 6 their contents,
/// 7 the existing note, 8 the annotation list when it is stored separately, 9 the font.
struct MiniPDF {
    enum Annotations {
        case inline          // /Annots [7 0 R]
        case separateList    // /Annots 8 0 R, where object 8 is the list
        case notAList        // /Annots << /Oops 1 >>
        case withStrayItem   // /Annots [7 0 R 42]
        case none
    }

    var annotationsKey = "/Annots"
    var annotations = Annotations.inline
    var duplicateAnnotationsKey = false
    var pageGeneration = 0
    var inheritPageSize = false
    var encrypted = false
    /// Rotation of page 1 in degrees, and an optional crop box for it such as "[50 400 450 780]".
    var rotation = 0
    var cropBox: String?
    /// macOS's writer lists unused numbers as "in use at position 0".
    var unusedSlotMarkedInUse = false
    /// Extra entries for the catalog and for page 1, written as PDF text.
    var catalogExtras = ""
    var pageExtras = ""
    /// Further objects, such as form fields.
    var extraObjects: [(number: Int, generation: Int, body: String)] = []
    /// Makes the index entries of these two objects point at each other's position.
    var swappedIndexEntries: (Int, Int)?
    /// What the page tree claims as its number of pages; the true number is 2.
    var declaredPageCount = 2

    // Ready-made catalog extras.
    static let formSayingSignaturesExist = " /AcroForm << /SigFlags 3 /Fields [] >>"
    static let usageRightsSeal = " /Perms << /UR3 << /Type /Sig /ByteRange [0 1 2 3] >> >> /AcroForm << /SigFlags 3 /Fields [] >>"
    static let certification = " /Perms << /DocMDP << /Type /Sig /ByteRange [0 1 2 3] >> >>"

    private func objects() -> [(number: Int, generation: Int, body: String)] {
        let size = "/MediaBox [0 0 612 792]"
        var annots = ""
        switch annotations {
        case .inline: annots = " \(annotationsKey) [7 0 R]"
        case .separateList: annots = " \(annotationsKey) 8 0 R"
        case .notAList: annots = " \(annotationsKey) << /Oops 1 >>"
        case .withStrayItem: annots = " \(annotationsKey) [7 0 R 42]"
        case .none: break
        }
        if duplicateAnnotationsKey { annots += " /Annots [7 0 R]" }
        func content(_ text: String) -> String {
            let stream = "BT /F1 18 Tf 72 700 Td (\(text)) Tj ET"
            return "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        }
        let pageOneSettings = (inheritPageSize ? "" : " " + size) + (rotation == 0 ? "" : " /Rotate \(rotation)")
            + (cropBox.map { " /CropBox " + $0 } ?? "") + pageExtras
        var list: [(number: Int, generation: Int, body: String)] = [
            (1, 0, "<< /Type /Catalog /Pages 2 0 R\(catalogExtras) >>"),
            (2, 0, "<< /Type /Pages /Kids [3 \(pageGeneration) R 4 0 R] /Count \(declaredPageCount)\(inheritPageSize ? " " + size : "") >>"),
            (3, pageGeneration, "<< /Type /Page /Parent 2 0 R\(pageOneSettings) /Contents 5 0 R /Resources << /Font << /F1 9 0 R >> >>\(annots) >>"),
            (4, 0, "<< /Type /Page /Parent 2 0 R\(inheritPageSize ? "" : " " + size) /Contents 6 0 R /Resources << /Font << /F1 9 0 R >> >> >>"),
            (5, 0, content("Hello page one")),
            (6, 0, content("Hello page two")),
            (7, 0, "<< /Type /Annot /Subtype /Text /Rect [72 600 92 620] /Contents (old note) >>"),
            (9, 0, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ]
        if case .separateList = annotations { list.append((8, 0, "[7 0 R]")) }
        list += extraObjects
        return list.sorted { $0.number < $1.number }
    }

    /// A file with an old-style index table.
    func classic() -> [UInt8] {
        var out = Array("%PDF-1.7\n".utf8)
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        for object in objects() {
            entries[object.number] = (out.count, object.generation)
            out += Array("\(object.number) \(object.generation) obj\n\(object.body)\nendobj\n".utf8)
        }
        if let (a, b) = swappedIndexEntries, let first = entries[a], let second = entries[b] {
            entries[a] = (second.offset, first.generation)
            entries[b] = (first.offset, second.generation)
        }
        let size = (entries.keys.max() ?? 0) + 1
        let start = out.count
        out += Array("xref\n0 \(size)\n".utf8)
        for number in 0..<size {
            if let entry = entries[number] {
                out += Array("\(MiniPDF.padded(entry.offset, 10)) \(MiniPDF.padded(entry.generation, 5)) n \n".utf8)
            } else {
                let inUse = unusedSlotMarkedInUse && number != 0
                out += Array("0000000000 \(number == 0 ? "65535" : "00000") \(inUse ? "n" : "f") \n".utf8)
            }
        }
        out += Array("trailer\n<< /Size \(size) /Root 1 0 R\(encrypted ? " /Encrypt << /Filter /Standard >>" : "") >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        return out
    }

    enum PackFault {
        case none
        case truncatedIndex      // the compressed index is cut short, so it will not decompress
        case shortIndex          // the index decompresses but holds fewer rows than it declares
        case wrongObjectInPack   // the pack's table of contents names a different object than the index does
        case oversizedField      // an index field is eight bytes of 0xFF
        case impossibleGeneration  // an index row gives an object version number above 65535
        case impossiblePack      // an index row says "inside pack 9000000"
        case hugeColumns         // the predictor's row width is the largest number there is
        case absurdPackCount     // the pack claims to hold a hundred million objects
        case packLengthInsidePack  // the pack's length is itself stored in the pack
        case packIsNotAPlainObject // an index row says "inside pack 9", and object 9 is itself inside a pack
        case packTableTooShort     // the pack claims three more objects than its table of contents lists
    }

    /// A file with a compressed index, with the catalog, page tree, pages and note stored in an object pack.
    /// - Parameters:
    ///   - usePredictor: store the index with the row predictor nearly every real file uses.
    ///   - blankBeforeObjects: record each position one byte early, on the line break before the object.
    func compressed(fault: PackFault = .none, usePredictor: Bool = false, blankBeforeObjects: Bool = false) -> [UInt8] {
        let all = objects()
        let packed = all.filter { [1, 2, 3, 4, 7, 9].contains($0.number) }
        let loose = all.filter { [5, 6].contains($0.number) }
        let early = blankBeforeObjects ? 1 : 0

        var table = "", bodies = ""
        for (position, object) in packed.enumerated() {
            let listed = (fault == .wrongObjectInPack && position == 2) ? 99 : object.number
            table += "\(listed) \(bodies.utf8.count) "
            bodies += object.body + "\n"
        }
        let packData = MiniPDF.deflate(Array((table + bodies).utf8))

        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int: Int] = [:]
        for object in loose {
            offsets[object.number] = out.count - early
            out += Array("\(object.number) 0 obj\n\(object.body)\nendobj\n".utf8)
        }
        offsets[10] = out.count - early
        let declaredCount = fault == .absurdPackCount ? 99_999_999 : (fault == .packTableTooShort ? packed.count + 3 : packed.count)
        let declaredLength = fault == .packLengthInsidePack ? "12 0 R" : "\(packData.count)"
        out += Array("10 0 obj\n<< /Type /ObjStm /N \(declaredCount) /First \(table.utf8.count) /Filter /FlateDecode /Length \(declaredLength) >>\nstream\n".utf8)
        out += packData
        out += Array("\nendstream\nendobj\n".utf8)

        let indexOffset = out.count
        offsets[11] = indexOffset - early
        let wide = fault == .oversizedField || fault == .impossibleGeneration
        let objectCount = fault == .packLengthInsidePack ? 13 : 12
        var rows: [[UInt8]] = []
        for number in 0..<objectCount {
            func tail(_ value: Int) -> [UInt8] {
                wide ? [UInt8](repeating: 0, count: 7) + [UInt8(value)] : [0, UInt8(value)]
            }
            if number == 12 {
                rows.append([2, 0, 0, 0, 10] + tail(0))  // the pack's own length, claimed to be inside the pack
            } else if let position = packed.firstIndex(where: { $0.number == number }) {
                let index = (fault == .oversizedField && position == 2) ? [UInt8](repeating: 0xFF, count: 8) : tail(position)
                // 9 000 000 as four bytes: beyond the format's highest object number.
                var pack: [UInt8] = (fault == .impossiblePack && position == 2) ? [0x00, 0x89, 0x54, 0x40] : [0, 0, 0, 10]
                if fault == .packIsNotAPlainObject && position == 2 { pack = [0, 0, 0, 9] }
                rows.append([2] + pack + index)
            } else if let offset = offsets[number] {
                // 70 000 as a version number: above the format's 65 535.
                let version: [UInt8] = (fault == .impossibleGeneration && number == 5) ? [0, 0, 0, 0, 0, 0x01, 0x11, 0x70] : tail(0)
                rows.append([1, UInt8((offset >> 24) & 0xFF), UInt8((offset >> 16) & 0xFF), UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF)] + version)
            } else {
                rows.append([0, 0, 0, 0, 0] + tail(0))
            }
        }
        if fault == .shortIndex { rows.removeLast(4) }
        let rowWidth = rows[0].count
        var plain: [UInt8] = []
        if usePredictor {
            var previous = [UInt8](repeating: 0, count: rowWidth)
            for row in rows {
                plain.append(2)  // "up": each byte is stored as its difference from the byte above
                plain += zip(row, previous).map { $0 &- $1 }
                previous = row
            }
        } else {
            plain = rows.flatMap { $0 }
        }
        var indexData = MiniPDF.deflate(plain)
        if fault == .truncatedIndex { indexData = Array(indexData.prefix(indexData.count / 2)) }
        var settings = usePredictor ? " /DecodeParms << /Predictor 12 /Columns \(rowWidth) >>" : ""
        if fault == .hugeColumns { settings = " /DecodeParms << /Predictor 12 /Columns 9223372036854775807 >>" }
        out += Array("11 0 obj\n<< /Type /XRef /Size \(objectCount) /W [1 4 \(wide ? 8 : 2)] /Root 1 0 R /Filter /FlateDecode\(settings) /Length \(indexData.count) >>\nstream\n".utf8)
        out += indexData
        out += Array("\nendstream\nendobj\nstartxref\n\(indexOffset - early)\n%%EOF\n".utf8)
        return out
    }

    /// Adds an update section after `base`, the way another program's later save would.
    /// - Parameters:
    ///   - objects: new versions of objects, or new objects.
    ///   - freed: numbers marked deleted in an old-style table.
    ///   - placeholders: numbers recorded as "in use at position 0".
    ///   - freedInCompressedPart: numbers marked deleted in the compressed half of a hybrid index.
    ///   - liveInCompressedPart: objects stored in an object pack and listed only in the compressed half of a
    ///     hybrid index, the way a program writing for both old and new readers does.
    ///   - previousPointsToItself: makes this section name itself as the previous one.
    ///   - rawIndexLines: text put into the index table as it is.
    ///   - previousPointer / size: override what the trailer says.
    static func update(_ base: [UInt8], objects: [(number: Int, generation: Int, body: String)] = [],
                       freed: [Int] = [], placeholders: [Int] = [], freedInCompressedPart: [Int] = [],
                       liveInCompressedPart: [(number: Int, body: String)] = [],
                       rawIndexLines: String = "", previousPointer: String? = nil, previousPointsToItself: Bool = false,
                       size: String = "30", trailerExtras: String = "") -> [UInt8] {
        var out = base
        var sections = rawIndexLines
        for object in objects {
            sections += "\(object.number) 1\n\(padded(out.count, 10)) \(padded(object.generation, 5)) n \n"
            out += Array("\(object.number) \(object.generation) obj\n\(object.body)\nendobj\n".utf8)
        }
        for number in freed { sections += "\(number) 1\n0000000000 00001 f \n" }
        for number in placeholders { sections += "\(number) 1\n0000000000 00000 n \n" }

        var hybridPointer = ""
        if !freedInCompressedPart.isEmpty || !liveInCompressedPart.isEmpty {
            func positionBytes(_ position: Int) -> [UInt8] {
                [UInt8((position >> 24) & 0xFF), UInt8((position >> 16) & 0xFF), UInt8((position >> 8) & 0xFF), UInt8(position & 0xFF)]
            }
            // An object pack (number 21) for the objects that live only in the compressed half.
            var packPosition = 0
            if !liveInCompressedPart.isEmpty {
                var table = "", bodies = ""
                for object in liveInCompressedPart {
                    table += "\(object.number) \(bodies.utf8.count) "
                    bodies += object.body + "\n"
                }
                let content = table + bodies
                packPosition = out.count
                out += Array("21 0 obj\n<< /Type /ObjStm /N \(liveInCompressedPart.count) /First \(table.utf8.count) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n".utf8)
            }
            // The compressed half itself (number 20): one row per number it describes, in ascending order.
            let position = out.count
            var described: [(number: Int, row: [UInt8])] = freedInCompressedPart.map { ($0, [0, 0, 0, 0, 0, 0, 0]) }
            for (index, object) in liveInCompressedPart.enumerated() { described.append((object.number, [2, 0, 0, 0, 21, 0, UInt8(index)])) }
            described.append((20, [1] + positionBytes(position) + [0, 0]))
            if !liveInCompressedPart.isEmpty { described.append((21, [1] + positionBytes(packPosition) + [0, 0])) }
            described.sort { $0.number < $1.number }
            let ranges = described.map { "\($0.number) 1" }.joined(separator: " ")
            let rows = described.flatMap { $0.row }
            out += Array("20 0 obj\n<< /Type /XRef /Size 30 /W [1 4 2] /Index [\(ranges)] /Length \(rows.count) >>\nstream\n".utf8)
            out += rows
            out += Array("\nendstream\nendobj\n".utf8)
            hybridPointer = " /XRefStm \(position)"
        }

        let text = String(decoding: base, as: UTF8.self)
        let start = out.count
        let previous = previousPointsToItself ? "\(start)"
            : (previousPointer ?? text.components(separatedBy: "startxref\n").last!.components(separatedBy: "\n").first!)
        out += Array("xref\n\(sections)trailer\n<< /Size \(size) /Root 1 0 R /Prev \(previous)\(hybridPointer)\(trailerExtras) >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        return out
    }

    static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    static func deflate(_ input: [UInt8]) -> [UInt8] {
        var length = uLongf(compressBound(uLong(input.count)))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = compress2(&output, &length, input, uLong(input.count), Z_BEST_COMPRESSION)
        precondition(status == Z_OK)
        return Array(output.prefix(Int(length)))
    }
}
