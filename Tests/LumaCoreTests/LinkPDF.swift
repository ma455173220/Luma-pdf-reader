import Foundation

/// A tiny three-page PDF whose first page carries one link of each kind, for testing link handling.
enum LinkPDF {
    /// Link areas on page 1, in page coordinates.
    static let toSpotOnPageThree = CGRect(x: 72, y: 690, width: 128, height: 30)   // leads to (100, 500) on page 3
    static let toPageTwo = CGRect(x: 72, y: 650, width: 128, height: 30)           // names page 2 only
    static let toWeb = CGRect(x: 72, y: 610, width: 128, height: 30)
    static let toLocalFile = CGRect(x: 72, y: 570, width: 128, height: 30)         // must be ignored
    static let toHeightOnPageThree = CGRect(x: 72, y: 530, width: 128, height: 30) // names height 300 on page 3
    static let overlappingWebLink = CGRect(x: 100, y: 695, width: 50, height: 20)  // lies on top of the first link

    private static func box(_ r: CGRect) -> String { "[\(Int(r.minX)) \(Int(r.minY)) \(Int(r.maxX)) \(Int(r.maxY))]" }

    static func bytes() -> [UInt8] {
        func content(_ text: String) -> String {
            let stream = "BT /F1 18 Tf 72 700 Td (\(text)) Tj ET"
            return "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        }
        func page(_ contents: Int, _ extras: String = "") -> String {
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contents) 0 R /Resources << /Font << /F1 9 0 R >> >>\(extras) >>"
        }
        func link(_ rect: CGRect, _ where_: String) -> String { "<< /Type /Annot /Subtype /Link /Rect \(box(rect)) /Border [0 0 0] \(where_) >>" }
        let objects: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"),
            (3, page(6, " /Annots [10 0 R 11 0 R 12 0 R 13 0 R 14 0 R 15 0 R]")),
            (4, page(7)),
            (5, page(8)),
            (6, content("Page one")),
            (7, content("Page two")),
            (8, content("Page three")),
            (9, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            (10, link(toSpotOnPageThree, "/Dest [5 0 R /XYZ 100 500 0]")),
            (11, link(toPageTwo, "/A << /S /GoTo /D [4 0 R /Fit] >>")),
            (12, link(toWeb, "/A << /S /URI /URI (https://doi.org/10.1000/example) >>")),
            (13, link(toLocalFile, "/A << /S /URI /URI (file:///etc/hosts) >>")),
            (14, link(toHeightOnPageThree, "/Dest [5 0 R /FitH 300]")),
            (15, link(overlappingWebLink, "/A << /S /URI /URI (https://example.org/on-top) >>")),
        ]
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int: Int] = [:]
        for (number, body) in objects {
            offsets[number] = out.count
            out += Array("\(number) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let start = out.count
        out += Array("xref\n0 16\n0000000000 65535 f \n".utf8)
        for number in 1...15 {
            let digits = String(offsets[number]!)
            out += Array("\(String(repeating: "0", count: 10 - digits.count))\(digits) 00000 n \n".utf8)
        }
        out += Array("trailer\n<< /Size 16 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8)
        return out
    }
}
