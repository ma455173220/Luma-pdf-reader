import CoreGraphics
import Foundation
import PDFKit

/// What a reference in the text names.
public enum FigureKind: Hashable {
    case figure, table, scheme
}

/// A place in the text that names figures or tables: "Fig. 3", "Figures 2a and 4", "Table II", "图 3".
public struct FigureMention {
    public let page: Int
    public let range: NSRange
    /// Each number written, with the rectangles it takes on the page (more than one when it runs over
    /// a line break). The first takes the word before it as well. Numbers inside a range ("Figs. 2–4")
    /// and those of supplementary material ("Fig. S3") have no part.
    public let parts: [(kind: FigureKind, number: Int, rects: [CGRect])]
    /// Written in Chinese ("图 3"); its caption is looked for in Chinese first.
    let chinese: Bool
}

/// The line a figure's or table's caption starts on: "Figure 3.", "FIG. 3.", "Table 2:", "Fig. 3 The…".
public struct FigureCaption: Equatable {
    public let kind: FigureKind
    public let number: Int
    public let page: Int
    /// Where the caption's label is in the page's text.
    public let range: NSRange
    /// How much the line looks like a caption: smaller type than the running text counts most, then
    /// a full stop or colon after the number, then a label in capitals.
    let strength: Int
    let chinese: Bool
    /// A table's caption repeated where the table goes on over a page ("Table 1 (continued)").
    let continued: Bool
}

/// Finds references to figures and tables in the text of a page, and the captions they lead to.
public enum FigureReferences {
    /// The word naming a figure or table, written before a number. "Fig." may follow a word without a
    /// space between, as in text that lost its spaces ("showninFig.4"). "图" and "表" are not taken
    /// where they end a longer word ("代表", "发表", "试图"), nor after 附 (an appendix's "附图 1").
    private static let word = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(FIG(?:URE)?S?\.?|TABLES?|SCHEMES?)\s*(?=S?\d|[IVX])|(?<![\p{Lu}\p{N}])(Fig(?:ure)?s?\.?|Tables?|Tab\.|Schemes?)\s*(?=S?\d|[IVX])|(?<![试企意地构绘插拼附])(图)\s*(?=S?\d)|(?<![代发列外仪报电时附])(表)\s*(?=S?\d)"#)
    /// A panel letter after a number: "3a", "3a–c", "3(b)", "3 (a and b)", "3a,b".
    private static let panel = try! NSRegularExpression(
        pattern: #"\G(?:\s?\(\s?[a-z](?:\s?(?:[–-]|and|,)\s?[a-z])*\s?\)|[a-zA-Z](?:\s?[–-]\s?[a-zA-Z])?(?![\p{L}]))(?:\s?,\s?[a-z](?![\p{L}\p{N}]))*"#)
    /// What joins two numbers of one reference: "2 and 4", "2, 4", "2–4" (a range), "2 和 4". A comma
    /// is also a sentence going on ("In Fig. 3, 2D materials…"), so a number after one counts only
    /// when the reference goes on or ends after it (see `endsAList`).
    private static let joiner = try! NSRegularExpression(pattern: #"\G\s*(,|、|and|&|–|-|−|和|及|与)\s*(?=S?\d|[IVX])"#)
    /// What may follow a number in a list of them: punctuation, another joining word, or the end.
    private static let listGoesOn = try! NSRegularExpression(pattern: #"\G\s*(?:$|[)\];.,:、，。；）]|and\b|&|[–\-−]|和|及|与)"#)
    /// Words before a reference to material outside the file, read across a line break ("Supplemen-
    /// tary Fig. 3", "Supplementary Information Fig. 2", "Extended Data Fig. 2", "ESI Fig. 1", "补充材料图 1").
    private static let supplementary = try! NSRegularExpression(
        pattern: #"(?:(?:supplementa\w*|supporting)(?:\s+(?:information|materials?|data|notes?|files?))?|suppl\.?|extended\s+data|esi|si|补充材料|补充信息|支撑材料|支撑信息|支持信息|附录)\s*[,，]?\s*中?\s*$"#, options: [.caseInsensitive])
    /// Words after a reference that put the figure in another work or in supplementary material
    /// ("Fig. 3 of ref. 12", "Table 2 in [7]", "Table 3 in the Supporting Information").
    private static let elsewhere = try! NSRegularExpression(
        pattern: #"^\s*[)\]]?\s*(?:of|in|from)\s+(?:the\s+|our\s+|their\s+)?(?:refs?\b|refs?\.|references?\b|\[|supporting|supplementa|esi\b|si\b|previous|earlier|prior|work\b|paper\b|study\b)"#, options: [.caseInsensitive])
    /// Words a sentence goes on with after a reference, which a caption's title does not start with.
    private static let sentenceGoesOn: Set<String> = ["but", "for", "and", "or", "of", "in", "on", "at", "to", "with", "from", "by", "as",
        "is", "are", "was", "were", "shows", "show", "showed", "shown", "presents", "gives", "displays", "illustrates", "depicts",
        "compares", "summarizes", "summarises", "lists", "reveals", "indicates", "demonstrates", "also", "which", "that", "where",
        "when", "while", "the", "a", "an", "we", "it", "its", "has", "have", "can", "could", "will", "would", "should", "may"]
    /// Words that start a sentence, which a caption's title does not start with.
    private static let sentenceStarts: Set<String> = ["The", "This", "These", "Those", "That", "There", "It", "Its", "We", "Our", "A", "An",
        "For", "In", "As", "At", "By", "On", "To", "With", "From", "Here", "However", "Thus", "Therefore", "Hence", "Moreover",
        "Furthermore", "Also", "Such", "Each", "All", "Both", "When", "While", "Since", "Although", "Note", "Similarly", "Compared",
        "Comparing", "Based", "According", "Besides", "Finally", "Then", "If", "Because", "Accordingly", "Clearly", "Obviously"]
    /// Words a sentence uses before a reference, which a running head does not end with.
    private static let leadIns: Set<String> = ["In", "See", "As", "From", "And", "Of", "To", "The", "This", "These", "Both", "With"]

    /// One label found in the text: the word, its numbers, and what surrounds it.
    struct Label {
        let range: NSRange
        let kind: FigureKind
        let chinese: Bool
        let plural: Bool
        let capitals: Bool
        /// Each number: the number (nil for supplementary material) and where it is written, with its
        /// panel letters.
        let numbers: [(number: Int?, range: NSRange)]
        let supplementary: Bool
    }

    /// Every label on a page, in the order of its text.
    static func labels(in attributed: NSAttributedString) -> [Label] {
        let text = attributed.string as NSString
        var found: [Label] = []
        for m in word.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let wordRange = (1...4).map { m.range(at: $0) }.first { $0.location != NSNotFound }!
            let written = text.substring(with: wordRange)
            let chinese = written == "图" || written == "表"
            let lower = written.lowercased()
            let kind: FigureKind = lower.hasPrefix("tab") || written == "表" ? .table : lower.hasPrefix("scheme") ? .scheme : .figure
            var numbers: [(Int?, NSRange)] = []
            var at = m.range.location + m.range.length
            var afterComma = false
            let pluralWord = !chinese && (written.filter(\.isLetter).hasSuffix("s") || written.filter(\.isLetter).hasSuffix("S"))
            while let item = number(in: attributed, at: at, kind: kind, chinese: chinese) {
                var end = item.end
                if let p = panel.firstMatch(in: text as String, range: NSRange(location: end, length: text.length - end)) { end += p.range.length }
                // After a comma, a number the sentence goes on from is no figure ("Fig. 4, 3 regimes"), unless
                // the word named several ("Figs. 5, 7, 9 correspond…").
                if afterComma && !pluralWord && listGoesOn.firstMatch(in: text as String, range: NSRange(location: end, length: text.length - end)) == nil { break }
                numbers.append((item.supplementary ? nil : item.value, NSRange(location: item.start, length: end - item.start)))
                guard let j = joiner.firstMatch(in: text as String, range: NSRange(location: end, length: text.length - end)) else { break }
                let joining = text.substring(with: j.range(at: 1))
                afterComma = joining == "," || joining == "、"
                at = end + j.range.length
            }
            guard let last = numbers.last else { continue }
            let range = NSRange(location: m.range.location, length: last.1.location + last.1.length - m.range.location)
            let before = text.substring(with: NSRange(location: max(0, m.range.location - 60), length: m.range.location - max(0, m.range.location - 60)))
                .replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "\u{2010}\n", with: "").replacingOccurrences(of: "\n", with: " ")
            let afterEnd = range.location + range.length
            let after = text.substring(with: NSRange(location: afterEnd, length: min(40, text.length - afterEnd))).replacingOccurrences(of: "\n", with: " ")
            let outside = supplementary.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
                || elsewhere.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) != nil
            let letters = written.filter(\.isLetter)
            found.append(Label(range: range, kind: kind, chinese: chinese, plural: !chinese && (letters.hasSuffix("s") || letters.hasSuffix("S")),
                               capitals: !chinese && letters == letters.uppercased(), numbers: numbers, supplementary: outside))
        }
        return found
    }

    /// A number written at `i`: "3", "S3" (supplementary), or for a table "II". Not one numbered within
    /// a chapter ("Figure 2.1"), which a figure of the same number may follow: a full stop and another
    /// number, unless that number is a raised citation ("Fig. 4.⁹²").
    private static func number(in attributed: NSAttributedString, at i: Int, kind: FigureKind, chinese: Bool) -> (value: Int, supplementary: Bool, start: Int, end: Int)? {
        let text = attributed.string as NSString
        func char(_ k: Int) -> Character? { k < text.length ? Character(UnicodeScalar(text.character(at: k)) ?? " ") : nil }
        func size(_ k: Int) -> CGFloat { (attributed.attribute(.font, at: k, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        var k = i
        let supplementary = char(k) == "S" && char(k + 1)?.isNumber == true
        if supplementary { k += 1 }
        var digits = ""
        while let c = char(k), c.isASCII, c.isNumber, digits.count < 4 { digits.append(c); k += 1 }
        if !digits.isEmpty {
            guard digits.count <= 3, let value = Int(digits), value > 0 else { return nil }
            if char(k) == ".", let next = char(k + 1), next.isASCII, next.isNumber, size(k + 1) > size(k - 1) * 0.85 { return nil }
            return (value, supplementary, i, k)
        }
        guard kind == .table, !chinese, !supplementary else { return nil }
        var roman = ""
        while let c = char(k), "IVX".contains(c), roman.count < 6 { roman.append(c); k += 1 }
        guard !roman.isEmpty, roman.count <= 5, char(k)?.isLetter != true, let value = romanValue(roman) else { return nil }
        return (value, false, i, k)
    }

    static func romanValue(_ s: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10]
        var total = 0, largest = 0
        for c in s.reversed() {
            guard let v = values[c] else { return nil }
            total += v < largest ? -v : v
            largest = max(largest, v)
        }
        return total > 0 ? total : nil
    }

    /// The references to figures and tables on a page, leaving out the captions themselves.
    public static func mentions(on page: PDFPage, index: Int, bodySize: CGFloat) -> [FigureMention] {
        guard let attributed = page.attributedString else { return [] }
        return labels(in: attributed).compactMap { label -> FigureMention? in
            guard !label.supplementary, caption(label, in: attributed, on: page, index: index, bodySize: bodySize) == nil else { return nil }
            var parts: [(FigureKind, Int, [CGRect])] = []
            for (i, item) in label.numbers.enumerated() {
                guard let number = item.number else { continue }
                let range = i == 0 ? NSRange(location: label.range.location, length: item.range.location + item.range.length - label.range.location) : item.range
                let rects = (page.selection(for: range)?.selectionsByLine() ?? []).map { $0.bounds(for: page) }.filter { $0.width > 0 }
                if !rects.isEmpty { parts.append((label.kind, number, rects)) }
            }
            return parts.isEmpty ? nil : FigureMention(page: index, range: label.range, parts: parts, chinese: label.chinese)
        }
    }

    /// The captions that start on a page.
    public static func captions(on page: PDFPage, index: Int, bodySize: CGFloat) -> [FigureCaption] {
        guard let attributed = page.attributedString else { return [] }
        return labels(in: attributed).compactMap { caption($0, in: attributed, on: page, index: index, bodySize: bodySize) }
    }

    /// The label as the start of a caption, or nil when it is a reference in running text.
    ///
    /// A caption starts a line with one number, followed by a space, a full stop or a colon, not by a
    /// panel letter or another number. It must also look like one: in smaller type than the running
    /// text, or with a full stop or colon after the number, or in capitals. A caption a running head
    /// was joined to ("…2007 Figure 5. Simulated…") is taken only in smaller type, and counts less.
    private static func caption(_ label: Label, in attributed: NSAttributedString, on page: PDFPage, index: Int, bodySize: CGFloat) -> FigureCaption? {
        let text = attributed.string as NSString
        guard label.numbers.count == 1, !label.plural, !label.supplementary, let number = label.numbers[0].number else { return nil }
        func char(_ k: Int) -> Character? { k >= 0 && k < text.length ? Character(UnicodeScalar(text.character(at: k)) ?? " ") : nil }
        let numberRange = label.numbers[0].range
        // Right after the number itself, before any panel letter.
        var end = numberRange.location
        while let c = char(end), c.isNumber || "IVXS".contains(c) { end += 1 }
        // Some files give a dash after the number as the letter e ("Table 1e Synthesis of…").
        let dash = char(end) == "e" && char(end + 1) == " " && (char(end + 2)?.isUppercase ?? false)
        if !dash, let c = char(end), c == "(" || c.isLetter || c.isNumber { return nil }
        var next = dash ? end + 1 : end
        while char(next) == " " { next += 1 }
        let stop = char(next).map { ".:|：".contains($0) } ?? false
        let full = dash || stop && !(char(next + 1)?.isNumber ?? false)
        // A sentence goes on after a reference with a small word ("Same as⏎Fig. 3 but for…", "see⏎Figure 3
        // for details"); a caption's title does not. (A caption's words may come out of order, so other
        // words in lower case are taken.)
        if !full {
            var w = next
            var word = ""
            while let c = char(w), c.isLetter { word.append(c); w += 1 }
            if sentenceGoesOn.contains(word) { return nil }
        }
        let size = (attributed.attribute(.font, at: numberRange.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        let small = bodySize > 0 && size > 0 && size <= bodySize - 0.4
        var strength = (small ? 2 : 0) + (full ? 1 : 0) + (label.capitals ? 1 : 0)
        if strength == 1, full {
            // Only a full stop to go by: the next sentence of the text ("…listed in⏎Table 3. For all…")
            // starts with words a caption's title does not.
            var w = next + 1
            while char(w) == " " { w += 1 }
            var word = ""
            while let c = char(w), c.isLetter { word.append(c); w += 1 }
            if sentenceStarts.contains(word) { return nil }
        }
        var start = label.range.location - 1
        while char(start) == " " || char(start) == "\t" { start -= 1 }
        let lineStart = start < 0 || char(start) == "\n"
        if !lineStart {
            // Joined to a running head: a capitalised word or a number just before it on the line.
            let lineBegin = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: start + 1)).location
            let from = lineBegin == NSNotFound ? 0 : lineBegin + 1
            let lead = text.substring(with: NSRange(location: from, length: start + 1 - from))
            let previous = lead.split(separator: " ").last.map(String.init) ?? ""
            let capitalised = previous.first.map { $0.isUppercase || $0.isNumber } ?? false
            let followedByCapital = char(next).map { $0.isUppercase } ?? false
            guard small, full || followedByCapital, capitalised, !leadIns.contains(previous), char(label.range.location - 1) == " " else { return nil }
            strength -= 1
        } else if !small, !label.capitals, start > 0 {
            // In the running text's own type, with only a full stop to go by: a sentence that ends with
            // the reference ("…are listed in⏎Table 3. For all…") when the line before, in the same type,
            // breaks off mid-sentence and the label's line sits right under it. A running head above a
            // caption is in a type of its own; a caption the text was broken around sits elsewhere.
            var k = start - 1
            while char(k) == " " { k -= 1 }
            let before = k >= 0 ? (attributed.attribute(.font, at: k, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 : 0
            if let last = char(k), last.isLowercase || last == ",", abs(before - size) <= 0.3 {
                let lineBegin = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: k)).location
                let from = lineBegin == NSNotFound ? 0 : lineBegin + 1
                if let above = page.selection(for: NSRange(location: from, length: k + 1 - from))?.bounds(for: page),
                   let here = page.selection(for: label.range)?.bounds(for: page),
                   here.maxY <= above.minY + 2, above.minY - here.maxY <= max(4, above.height * 0.6), abs(here.minX - above.minX) <= 15 {
                    return nil
                }
            }
        }
        guard strength >= 1 else { return nil }
        let after = text.substring(with: NSRange(location: end, length: min(24, text.length - end)))
        let continued = after.range(of: #"^\s*[.:|]?\s*[-–—(]?\s*(?:continued|cont\.|cont['’]d|续)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return FigureCaption(kind: label.kind, number: number, page: index, range: label.range, strength: strength,
                             chinese: label.chinese, continued: continued)
    }

    /// A line of a page's text and where it is.
    struct TextLine {
        let rect: CGRect
        let range: NSRange
        let size: CGFloat
        let letters: Int
    }

    static func lines(of page: PDFPage) -> [TextLine] {
        guard let attributed = page.attributedString else { return [] }
        let text = attributed.string as NSString
        var result: [TextLine] = []
        var start = 0
        while start < text.length {
            let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start)).location
            let end = newline == NSNotFound ? text.length : newline
            let range = NSRange(location: start, length: end - start)
            if end > start, let rect = page.selection(for: range)?.bounds(for: page), rect.width > 0 {
                var letters = 0
                var size: CGFloat = 0
                for k in start..<end where !(Character(UnicodeScalar(text.character(at: k)) ?? " ").isWhitespace) {
                    // A Chinese or Japanese character takes the room of about two Latin letters.
                    let u = text.character(at: k)
                    letters += (0x2E80...0x9FFF).contains(u) || (0xAC00...0xD7AF).contains(u) || (0xFF00...0xFFEF).contains(u) ? 2 : 1
                    if size == 0 { size = (attributed.attribute(.font, at: k, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
                }
                result.append(TextLine(rect: rect, range: range, size: size, letters: letters))
            }
            start = end + 1
        }
        return result
    }

    /// Where a preview of a caption's figure or table starts.
    ///
    /// A table's caption is above the table, so the preview starts at the caption. A figure's caption
    /// is below the figure: the preview starts just under the nearest line of running text above the
    /// caption (a line of the body, or of another caption), or at the top of the page when there is
    /// none. Text inside the figure (axis labels, panel letters) is passed over: it is short, or
    /// thinly spread across the width. A figure caption at the head of a page, with no room above it
    /// for anything but a running head, belongs to a figure that fills the page before; the preview
    /// starts at the top of that page.
    public static func target(of caption: FigureCaption, in document: PDFDocument) -> (page: Int, point: CGPoint)? {
        guard let page = document.page(at: caption.page) else { return nil }
        let lines = lines(of: page)
        guard let index = lines.firstIndex(where: { NSLocationInRange(caption.range.location, $0.range) }) else {
            let rect = page.selection(for: caption.range)?.bounds(for: page) ?? .zero
            return (caption.page, CGPoint(x: rect.minX, y: rect.maxY))
        }
        let line = lines[index]
        // The caption's own part of its line: a running head may come before it in the text.
        let end = line.range.location + line.range.length
        let own = page.selection(for: NSRange(location: caption.range.location, length: end - caption.range.location))?.bounds(for: page) ?? line.rect
        if caption.kind == .table { return (caption.page, CGPoint(x: own.minX, y: own.maxY)) }
        // The caption's width: its first line and those after it in the same type.
        var left = own.minX, right = own.maxX
        var previous = own
        for other in lines[(index + 1)...].prefix(8) {
            guard abs(other.size - line.size) <= 0.3, other.rect.maxY <= previous.minY + 2, other.rect.maxY >= previous.minY - 6,
                  abs(other.rect.minX - left) <= 30 else { break }
            left = min(left, other.rect.minX); right = max(right, other.rect.maxX)
            previous = other.rect
        }
        // Lines set right above the caption in its own small type belong to it: a caption in a second
        // language, or the panels' descriptions some journals put between the figure and its caption.
        // They are in the caption's own size and written densely, unlike the labels inside a figure. (A
        // short last line of such a description may not reach under a caption set in the middle; the
        // other column of the page is not looked into.)
        let pageBox = page.bounds(for: .cropBox)
        let inLeftColumn = right < pageBox.midX + 10, inRightColumn = left > pageBox.midX - 10
        let reachLeft = inRightColumn ? max(left - 60, pageBox.midX - 10) : left - 60
        let reachRight = inLeftColumn ? min(right + 60, pageBox.midX + 10) : right + 60
        var block = own
        while let above = lines.filter({ other in
            other.rect.minY >= block.maxY - 1 && min(other.rect.maxX, reachRight) - max(other.rect.minX, reachLeft) > 0
        }).min(by: { $0.rect.minY < $1.rect.minY }),
            abs(above.size - line.size) <= 0.4, CGFloat(above.letters) * max(above.size, 1) / above.rect.width >= 1.2,
            above.rect.minY - block.maxY <= max(above.rect.height, block.height) * 0.8 + 2 {
            block = block.union(above.rect)
        }
        let running = lines.filter { other in
            guard other.rect.minY >= block.maxY - 1, other.rect.width >= pageBox.width * 0.3 else { return false }
            let overlap = min(other.rect.maxX, right) - max(other.rect.minX, left)
            // Written densely: about as many letters as running text of its size would fit in its width.
            return overlap >= min(other.rect.width, right - left) * 0.3 && CGFloat(other.letters) * max(other.size, 1) / other.rect.width >= 1.2
        }
        let top = running.map(\.rect.minY).min().map { $0 - 1 } ?? pageBox.maxY
        if running.isEmpty, top - block.maxY < 70, caption.page > 0,
           let before = document.page(at: caption.page - 1) {
            return (caption.page - 1, CGPoint(x: left, y: before.bounds(for: .cropBox).maxY))
        }
        return (caption.page, CGPoint(x: left, y: top))
    }
}

/// Links worked out from a document's text for its references to figures and tables: each leads to
/// the figure or table, found by its caption within five pages either way.
///
/// Nothing is read until asked: each page the first time its links are asked for, and the pages
/// around it as far as the caption sought only when a link is used. What has been worked out is
/// kept, and is small.
///
/// It reads either the document shown, or one it is given each time it reads (a `TextReader`'s,
/// let go of between uses, so that the text read does not stay with the document shown; ADR 0006).
public final class FigureDecoder {
    private let shown: PDFDocument?
    private let reading: (() -> PDFDocument?)?
    private let pageCount: Int

    private var document: PDFDocument? { shown ?? reading?() }
    private var bodySize: CGFloat?
    private var captions: [Int: [FigureCaption]] = [:]
    /// By the caption's page, then by where the caption is in that page's text.
    private var targets: [Int: [Int: (page: Int, point: CGPoint)]] = [:]
    private var pages: [Int: [PageLink]] = [:]
    /// How far from a reference its caption is looked for.
    static let reach = 5

    private var resolved: [Reference: PageLink.Target?] = [:]
    private struct Reference: Hashable { let kind: FigureKind; let number: Int; let chinese: Bool; let page: Int }

    /// `bodySize`: the type size of the running text, if known already; 0 when it could not be found
    /// (then no type counts as smaller than it).
    public init(document: PDFDocument, bodySize: CGFloat? = nil) {
        shown = document
        reading = nil
        pageCount = document.pageCount
        self.bodySize = bodySize
    }

    /// A decoder that reads the document `reader` gives it when it needs one; `pageCount` is that of
    /// the document shown.
    public init(reading reader: TextReader, pageCount: Int, bodySize: CGFloat?) {
        shown = nil
        reading = { [weak reader] in reader?.document }
        self.pageCount = pageCount
        self.bodySize = bodySize
    }

    private var body: CGFloat {
        if let bodySize { return bodySize }
        // From a couple of pages past the title page, when there are some.
        guard let document else { return 0 }
        let first = document.pageCount > 2 ? 1 : 0
        let found = CitationMarkers.bodySize(of: (first..<min(first + 2, document.pageCount)).compactMap { document.page(at: $0) }) ?? 0
        bodySize = found
        return found
    }

    public func mentions(onPage index: Int) -> [FigureMention] {
        guard let page = document?.page(at: index) else { return [] }
        return FigureReferences.mentions(on: page, index: index, bodySize: body)
    }

    func captions(onPage index: Int) -> [FigureCaption] {
        if let cached = captions[index] { return cached }
        let found = document?.page(at: index).map { FigureReferences.captions(on: $0, index: index, bodySize: body) } ?? []
        captions[index] = found
        return found
    }

    /// The caption of figure or table `number` for a reference on page `index`: the one that looks most
    /// like a caption within reach. Pages are read outward from the reference, and once a caption in
    /// smaller type or in capitals is found, one page further either way, no more. Nil when there is
    /// none, or two that look as much like it (in a document in two languages, one in the reference's
    /// own language first).
    public func caption(of kind: FigureKind, _ number: Int, near index: Int, chinese: Bool = false) -> FigureCaption? {
        var found: [FigureCaption] = []
        var last = Self.reach
        for distance in 0...Self.reach where distance <= last {
            for p in Set([index - distance, index + distance]) where p >= 0 && p < pageCount {
                found += captions(onPage: p).filter { $0.kind == kind && $0.number == number && !$0.continued }
            }
            if last == Self.reach, found.contains(where: { $0.strength >= 2 }) { last = distance + 1 }
        }
        guard let strongest = found.map(\.strength).max() else { return nil }
        var best = found.filter { $0.strength == strongest }
        if best.contains(where: { $0.chinese == chinese }) { best = best.filter { $0.chinese == chinese } }
        return best.count == 1 ? best[0] : nil
    }

    /// Where a preview of the caption's figure or table starts.
    public func target(of caption: FigureCaption) -> (page: Int, point: CGPoint)? {
        if let known = targets[caption.page]?[caption.range.location] { return known }
        guard let document, let found = FigureReferences.target(of: caption, in: document) else { return nil }
        targets[caption.page, default: [:]][caption.range.location] = found
        return found
    }

    /// Links for the references on a page, leaving out any that would lie over one of `existing`.
    /// Where each leads is not looked for yet: that is done for the one the pointer comes to rest on
    /// (see `resolved(_:onPage:)`), so that moving over a page reads no other page.
    public func pendingLinks(onPage index: Int, besides existing: [PageLink] = []) -> [PageLink] {
        if let cached = pages[index] { return cached }
        var links: [PageLink] = []
        for mention in mentions(onPage: index) {
            for part in mention.parts {
                let rects = part.rects.map { $0.insetBy(dx: -1, dy: -1) }
                guard !existing.contains(where: { link in rects.contains { $0.intersects(link.rect) } }) else { continue }
                for rect in rects {
                    links.append(PageLink(rect: rect, target: .figure(kind: part.kind, number: part.number, chinese: mention.chinese)))
                }
            }
        }
        pages[index] = links
        return links
    }

    /// A link from `pendingLinks` on page `index`, with the place it leads to; nil when its figure or
    /// table cannot be found. Other links are returned as they are.
    public func resolved(_ link: PageLink, onPage index: Int) -> PageLink? {
        guard case .figure(let kind, let number, let chinese) = link.target else { return link }
        let key = Reference(kind: kind, number: number, chinese: chinese, page: index)
        if resolved[key] == nil {
            let target = caption(of: kind, number, near: index, chinese: chinese).flatMap { target(of: $0) }
            resolved[key] = .some(target.map { PageLink.Target.place(page: $0.page, point: $0.point) })
        }
        return resolved[key]!.map { PageLink(rect: link.rect, target: $0) }
    }

    /// The links for the references on a page with the places they lead to, all found at once.
    public func links(onPage index: Int, besides existing: [PageLink] = []) -> [PageLink] {
        pendingLinks(onPage: index, besides: existing).compactMap { resolved($0, onPage: index) }
    }
}
