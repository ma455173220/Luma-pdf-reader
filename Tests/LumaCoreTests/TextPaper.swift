import Foundation

/// A small paper of text for the decoding tests: each page is a list of lines, each line a list of
/// runs (text, size, rise). Lines are 14 points apart from the top of a US Letter page, starting 72
/// points in; a line without runs is left blank.
enum TextPaper {
    typealias Run = (text: String, size: Double, rise: Double)

    static func data(_ pages: [[[Run]]]) -> Data {
        var objects: [String]
        var kids: [Int]
        objects = ["<< /Type /Catalog /Pages 2 0 R >>", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>"]
        kids = []
        for lines in pages {
            var stream = "BT /F1 10 Tf 14 TL 72 740 Td\n"
            for line in lines {
                for run in line {
                    let escaped = run.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
                    stream += "/F1 \(run.size) Tf \(run.rise) Ts (\(escaped)) Tj\n"
                }
                stream += "0 Ts T*\n"
            }
            stream += "ET"
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
            let contents = objects.count
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(contents) 0 R /Resources << /Font << /F1 3 0 R >> >> >>")
            kids.append(objects.count)
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>"
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let start = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(out.utf8)
    }
}
