import CoreGraphics
import Foundation
import PDFKit

/// The fonts a page's text is set in, read from the page's own content.
///
/// The system engine gives each character of a page's text a size but not the font it was set in,
/// so bold and italic cannot be told from it. Here the page's content is read for where each piece
/// of text starts and the font named for it. Where a piece ends is not worked out: that needs the
/// widths of the font's glyphs.
public enum PageFonts {
    public struct Run: Equatable {
        /// The font's name, without the prefix a subset of it is given ("ABCDEF+Helvetica-Bold" is
        /// "Helvetica-Bold").
        public let font: String
        /// The size the text appears at on the page.
        public let size: CGFloat
        /// Where the piece of text starts, in page coordinates.
        public let origin: CGPoint
        /// How much text the piece holds, in bytes of the content.
        public let length: Int
    }

    /// The pieces of text on a page, in the order the page's content draws them.
    public static func runs(of page: PDFPage) -> [Run] {
        guard let cgPage = page.pageRef else { return [] }
        let reader = Reader()
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        reader.scan(stream)
        CGPDFContentStreamRelease(stream)
        return reader.runs
    }

    /// Whether a font's name marks it bold, or italic. Besides the usual words, the names TeX gives
    /// its fonts ("CMBX10" bold, "CMTI9" italic) and the endings some publishers add (".B", ".I").
    public static func isBold(_ font: String) -> Bool {
        let name = font.lowercased()
        return ["bold", "black", "heavy", "semibold", "demi", "-bd", ",bd", "medium", "-medi"].contains { name.contains($0) }
            || name.hasSuffix("-b") || name.hasSuffix("-sb") || name.hasSuffix("bd") || name.hasSuffix(".b") || name.hasSuffix(".bi")
            || name.hasPrefix("cmbx") || name.hasPrefix("cmb10") || name.hasPrefix("cmssbx")
    }

    public static func isItalic(_ font: String) -> Bool {
        let name = font.lowercased()
        return ["italic", "oblique", "-it", ",it", "-ital"].contains { name.contains($0) } || name.hasSuffix("-i") || name.hasSuffix("-bi")
            || name.hasSuffix(".i") || name.hasSuffix(".bi") || name.hasPrefix("cmti") || name.hasPrefix("cmsl") || name.hasPrefix("cmbxti")
    }

    /// Follows the content's graphics and text state just far enough to know where text starts.
    fileprivate final class Reader {
        var runs: [Run] = []
        var ctm = CGAffineTransform.identity
        /// What q saves and Q restores: the transform, and the text state that is part of the graphics state.
        var saved: [(ctm: CGAffineTransform, font: String, size: CGFloat, leading: CGFloat)] = []
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var leading: CGFloat = 0
        var font = ""
        var fontSize: CGFloat = 0
        /// Forms inside forms are followed this deep, no further; a form is never followed into itself,
        /// and no more than `formBudget` forms are followed on a page in all, so that a file drawing a
        /// form within a form many times over cannot keep the reader busy without end.
        var depth = 0
        var formsOnPath: Set<Int> = []
        var formsFollowed = 0
        static let formBudget = 2000
        private static let table: CGPDFOperatorTableRef = makeTable()

        func scan(_ stream: CGPDFContentStreamRef) {
            let scanner = CGPDFScannerCreate(stream, Self.table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
        }

        func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
            lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
            textMatrix = lineMatrix
        }

        func show(_ length: Int) {
            guard length > 0, !font.isEmpty else { return }
            let m = textMatrix.concatenating(ctm)
            let scale = (m.c * m.c + m.d * m.d).squareRoot()
            runs.append(Run(font: font, size: fontSize * scale, origin: CGPoint.zero.applying(m), length: length))
        }

        private static func makeTable() -> CGPDFOperatorTableRef {
            let table = CGPDFOperatorTableCreate()!
            CGPDFOperatorTableSetCallback(table, "q") { _, info in let r = reader(info); r.saved.append((r.ctm, r.font, r.fontSize, r.leading)) }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                let r = reader(info)
                guard let last = r.saved.popLast() else { return }
                (r.ctm, r.font, r.fontSize, r.leading) = last
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                guard let v = numbers(scanner, 6) else { return }
                let r = reader(info)
                r.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(r.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "BT") { _, info in let r = reader(info); r.textMatrix = .identity; r.lineMatrix = .identity }
            CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
                var size: CGPDFReal = 0
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
                let r = reader(info)
                r.fontSize = size
                r.font = fontName(scanner, String(cString: name))
            }
            CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in if let v = numbers(scanner, 1) { reader(info).leading = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in if let v = numbers(scanner, 2) { reader(info).moveLine(v[0], v[1]) } }
            CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
                guard let v = numbers(scanner, 2) else { return }
                let r = reader(info)
                r.leading = -v[1]
                r.moveLine(v[0], v[1])
            }
            CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
                guard let v = numbers(scanner, 6) else { return }
                let r = reader(info)
                r.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                r.textMatrix = r.lineMatrix
            }
            CGPDFOperatorTableSetCallback(table, "T*") { _, info in let r = reader(info); r.moveLine(0, -r.leading) }
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in reader(info).show(stringLength(scanner)) }
            CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                let r = reader(info)
                r.moveLine(0, -r.leading)
                r.show(stringLength(scanner))
            }
            CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                let length = stringLength(scanner)
                _ = numbers(scanner, 2)
                let r = reader(info)
                r.moveLine(0, -r.leading)
                r.show(length)
            }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &array), let array else { return }
                var length = 0
                for i in 0..<CGPDFArrayGetCount(array) {
                    var string: CGPDFStringRef?
                    if CGPDFArrayGetString(array, i, &string), let string { length += CGPDFStringGetLength(string) }
                }
                reader(info).show(length)
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name else { return }
                let r = reader(info)
                let content = CGPDFScannerGetContentStream(scanner)
                guard r.depth < 8, let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream),
                      !r.formsOnPath.contains(unsafeBitCast(stream, to: Int.self)), r.formsFollowed < Reader.formBudget else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                var matrix: CGPDFArrayRef?
                var form = CGAffineTransform.identity
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { _ = CGPDFArrayGetNumber(matrix, i, &v[i]) }
                    form = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? CGPDFStreamGetDictionary(stream)!, content)
                let outer = (ctm: r.ctm, text: r.textMatrix, line: r.lineMatrix, font: r.font, size: r.fontSize, leading: r.leading, saved: r.saved)
                r.ctm = form.concatenating(r.ctm)
                r.depth += 1
                r.formsFollowed += 1
                r.formsOnPath.insert(unsafeBitCast(stream, to: Int.self))
                r.scan(inner)
                r.formsOnPath.remove(unsafeBitCast(stream, to: Int.self))
                r.depth -= 1
                (r.ctm, r.textMatrix, r.lineMatrix, r.font, r.fontSize, r.leading, r.saved) = outer
                CGPDFContentStreamRelease(inner)
            }
            return table
        }
    }
}

// The content reader's helpers, outside the class so that its callbacks capture nothing.
fileprivate func reader(_ info: UnsafeMutableRawPointer?) -> PageFonts.Reader { Unmanaged<PageFonts.Reader>.fromOpaque(info!).takeUnretainedValue() }

fileprivate func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values = [CGFloat](repeating: 0, count: count)
    for i in (0..<count).reversed() {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
        values[i] = value
    }
    return values
}

fileprivate func stringLength(_ scanner: CGPDFScannerRef) -> Int {
    var string: CGPDFStringRef?
    guard CGPDFScannerPopString(scanner, &string), let string else { return 0 }
    return CGPDFStringGetLength(string)
}

/// The name of a font resource, from its BaseFont, or failing that its resource name.
fileprivate func fontName(_ scanner: CGPDFScannerRef, _ resource: String) -> String {
    guard let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", resource) else { return resource }
    var dictionary: CGPDFDictionaryRef?
    guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return resource }
    var base: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(dictionary, "BaseFont", &base), let base else { return resource }
    let name = String(cString: base)
    if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 { return String(name[name.index(after: plus)...]) }
    return name
}
