import Foundation

/// A tiny three-page PDF with an outline three levels deep, for testing how outlines are read.
///
///   1. Introduction            → page 1, at (72, 700)
///   2. Results                 → page 2 (page only)
///      2.1 First               → page 2, at (72, 400)
///      2.2 Second              → page 3 (page only)
///          2.2.1 Deep          → page 3, at (72, 300)
///   References 参考文献         → page 3, at (72, 100)
enum OutlinePDF {
    static func bytes(withOutline: Bool = true) -> [UInt8] {
        func content(_ text: String) -> String {
            let stream = "BT /F1 18 Tf 72 700 Td (\(text)) Tj ET"
            return "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        }
        func page(_ contents: Int) -> String {
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contents) 0 R /Resources << /Font << /F1 9 0 R >> >> >>"
        }
        // "References 参考文献" as UTF-16 with a byte-order mark, the way non-Latin titles are stored.
        let unicodeTitle = "<" + "References 参考文献".utf16.reduce(into: "FEFF") { $0 += String(format: "%04X", $1) } + ">"
        var objects: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R\(withOutline ? " /Outlines 20 0 R" : "") >>"),
            (2, "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"),
            (3, page(6)), (4, page(7)), (5, page(8)),
            (6, content("Page one")), (7, content("Page two")), (8, content("Page three")),
            (9, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ]
        if withOutline {
            objects += [
                (20, "<< /Type /Outlines /First 21 0 R /Last 26 0 R /Count 6 >>"),
                (21, "<< /Title (1. Introduction) /Parent 20 0 R /Next 22 0 R /Dest [3 0 R /XYZ 72 700 0] >>"),
                (22, "<< /Title (2. Results) /Parent 20 0 R /Prev 21 0 R /Next 26 0 R /First 23 0 R /Last 24 0 R /Count 3 /Dest [4 0 R /Fit] >>"),
                (23, "<< /Title (2.1 First) /Parent 22 0 R /Next 24 0 R /A << /S /GoTo /D [4 0 R /XYZ 72 400 0] >> >>"),
                (24, "<< /Title (2.2 Second) /Parent 22 0 R /Prev 23 0 R /First 25 0 R /Last 25 0 R /Count 1 /Dest [5 0 R /Fit] >>"),
                (25, "<< /Title (2.2.1 Deep) /Parent 24 0 R /Dest [5 0 R /XYZ 72 300 0] >>"),
                (26, "<< /Title \(unicodeTitle) /Parent 20 0 R /Prev 22 0 R /Dest [5 0 R /XYZ 72 100 0] >>"),
            ]
        }
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int: Int] = [:]
        for (number, body) in objects {
            offsets[number] = out.count
            out += Array("\(number) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let size = (offsets.keys.max() ?? 0) + 1
        let start = out.count
        out += Array("xref\n0 \(size)\n".utf8)
        for number in 0..<size {
            if let offset = offsets[number] {
                let digits = String(offset)
                out += Array("\(String(repeating: "0", count: 10 - digits.count))\(digits) 00000 n \n".utf8)
            } else {
                out += Array("0000000000 \(number == 0 ? "65535" : "00000") f \n".utf8)
            }
        }
        out += Array("trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        return out
    }
}
