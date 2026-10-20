import CoreGraphics
import Foundation

/// Turns text selected in a PDF into text that reads as it should once pasted.
///
/// A PDF stores lines, not paragraphs. Copied as they are, the lines of a paragraph arrive with a
/// break after each one, words split at the end of a line keep their hyphen and break apart, and
/// letters the typesetter joined (ﬁ, ﬂ) come out as single symbols. This joins the lines of a
/// paragraph, mends the split words, spells the joined letters out, and leaves out the running
/// heads, feet and page numbers met where the selection turns a page (only those the caller
/// recognises as repeating from page to page: a line is never dropped on position alone), keeping
/// the breaks between paragraphs. Paragraphs are found from the layout alone, so some slip through: a heading set in
/// the body's own size and weight runs into the paragraph after it.
public enum CleanCopy {
    /// One line of the selection: its text, where it is on its page (PDF coordinates, y upwards),
    /// which page, and that page's visible area (zero when not known).
    public struct Line: Equatable {
        public var text: String
        public var frame: CGRect
        public var page: Int
        public var pageBox: CGRect

        public init(text: String, frame: CGRect, page: Int, pageBox: CGRect = .zero) {
            self.text = text
            self.frame = frame
            self.page = page
            self.pageBox = pageBox
        }
    }

    /// - Parameter isWord: whether a run of Latin letters is a word, used to decide whether a hyphen
    ///   at the end of a line only split a word (electro-|chemical) or belongs to it (two-|dimensional).
    /// - Parameter isRunning: whether a line in the top or bottom strip of its page is a running head,
    ///   foot or page number: text that recurs in the same strip of the pages around it.
    public static func text(from lines: [Line], isWord: (String) -> Bool, isRunning: (Line) -> Bool = { _ in false }) -> String {
        var kept: [Line] = []
        var softBreak: [Bool] = []                          // the line ends where a soft hyphen allowed a break
        for line in lines {
            let raw = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = normalized(raw)
            guard !text.isEmpty else { continue }
            kept.append(Line(text: text, frame: line.frame, page: line.page, pageBox: line.pageBox))
            softBreak.append(raw.hasSuffix("\u{00AD}"))
        }
        let shapes = shapes(of: kept)
        let keep = kept.indices.filter { !leftOutAtPageTurn($0, in: kept, isRunning: isRunning) }
        guard let first = keep.first else { return "" }
        var out = kept[first].text
        for (previous, i) in zip(keep, keep.dropFirst()) {
            let next = kept[i].text
            if softBreak[previous] {
                out += next                                 // a word carries on: whatever the layout, no break
            } else if isEntryMarker(kept[previous].text) {
                out += " " + next                           // "52." standing alone: its entry follows
            } else if !continuesWord(out, next) && paragraphEnds(between: previous, and: i, in: kept, shapes: shapes) {
                out += "\n" + next
            } else {
                out = joined(out, next, isWord: isWord)
            }
        }
        return out
    }

    // MARK: Lines

    private static let ligatures: [Character: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]

    static func normalized(_ text: String) -> String {
        var out = ""
        for character in text {
            if let spelled = ligatures[character] {
                out += spelled
            } else if character == "\u{00AD}" {
                continue                                    // a soft hyphen only marks where a word may break
            } else if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                out += character == "\t" ? "\t" : " "
            } else {
                out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The share of the page's height, at its top and at its bottom, where running heads, feet and
    /// page numbers stand.
    public static let marginShare: CGFloat = 0.1

    /// Lines in the strip along the top or bottom edge of the page.
    private static func inMargin(_ line: Line) -> Bool {
        let box = line.pageBox
        guard box.height > 0 else { return false }
        let band = box.height * marginShare
        return line.frame.minY >= box.maxY - band || line.frame.maxY <= box.minY + band
    }

    /// A running head, foot or page number at the start or end of a page's part of a selection that
    /// runs on from or to another page.
    private static func leftOutAtPageTurn(_ i: Int, in lines: [Line], isRunning: (Line) -> Bool) -> Bool {
        let page = lines[i].page
        let pageRange = lines.indices.filter { lines[$0].page == page }
        guard let start = pageRange.first, let end = pageRange.last else { return false }
        let turnsBefore = start > 0, turnsAfter = end + 1 < lines.count
        func running(_ k: Int) -> Bool { inMargin(lines[k]) && isRunning(lines[k]) }
        // Heads at the top of a page the selection came onto, feet at the bottom of a page it leaves.
        if turnsBefore, (start...i).allSatisfy(running) { return true }
        if turnsAfter, (i...end).allSatisfy(running) { return true }
        return false
    }

    /// Text reduced to what a running head keeps from page to page: its letters, without the
    /// page numbers, spaces and punctuation that change. Empty for a line without letters.
    public static func runningKey(_ text: String) -> String {
        normalized(text).lowercased().filter { $0.isLetter }
    }

    /// The number a line consists of, if it is nothing but a number (a page number, perhaps).
    public static func bareNumber(_ text: String) -> Int? {
        let trimmed = normalized(text)
        guard !trimmed.isEmpty, trimmed.count <= 5, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }

    /// What a run of lines standing one under another in one column of one page looks like.
    struct Shape {
        var count: Int
        var left: CGFloat           // where most of its lines start
        var leftmost: CGFloat
        var right: CGFloat          // where its full lines end; a wide caption among them does not move it
        var gap: CGFloat?           // the usual space between one line and the next, when there are enough lines to tell
        var height: CGFloat
        var hangs: Bool             // first lines stick out to the left of the rest (references, lists)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// A line that is nothing but the number of a list or reference entry: 52., [52], (52).
    static func isEntryMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 6 else { return false }
        let inner = t.trimmingCharacters(in: CharacterSet(charactersIn: "[]().:"))
        return !inner.isEmpty && inner.allSatisfy({ $0.isNumber }) && (t.hasSuffix(".") || t.hasSuffix(")") || t.hasSuffix("]"))
    }

    /// Whether a line starts the way an entry of a list or of references does: [12], (a), 3., 4), •.
    private static func startsLikeEntry(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•·–-".contains(first) { return true }
        let rest = text.dropFirst()
        if first == "[" || first == "(" {
            let inside = rest.prefix { $0 != "]" && $0 != ")" }
            return !inside.isEmpty && inside.count <= 8 && rest.dropFirst(inside.count).first.map { $0 == "]" || $0 == ")" } == true
        }
        if first.isNumber {
            let digits = text.prefix { $0.isNumber }
            let after = text.dropFirst(digits.count)
            return digits.count <= 3 && (after.first == "." || after.first == ")") && after.dropFirst().first?.isWhitespace == true
        }
        return false
    }

    /// The shape of the run each line stands in.
    private static func shapes(of lines: [Line]) -> [Shape] {
        var result: [Shape] = []
        var start = 0
        func close(_ end: Int) {
            let run = Array(lines[start..<end])
            let height = max(median(run.map(\.frame.height)), 1)
            let leftmost = run.map(\.frame.minX).min() ?? 0
            // Where full lines end: the furthest place where at least two lines end together, as the
            // full lines of a justified column do. A single line reaching further (a caption across
            // both columns, a line set a little wide) does not move it. Ragged text: the longest line.
            let ends = run.map(\.frame.maxX).sorted(by: >)
            let together = ends.first { end in ends.filter { abs($0 - end) <= height * 0.15 }.count >= 2 }
            let right = together ?? ends.first ?? 0
            // The usual space between lines is the smaller kind: the larger kind separates paragraphs.
            let gaps = zip(run, run.dropFirst()).map { $0.frame.minY - $1.frame.maxY }.sorted()
            // Lines at the left edge against lines set in from it. References and lists hang: their
            // entries start at the edge and carry on set in. It takes two entries to tell.
            let outer = run.filter { $0.frame.minX - leftmost < height * 0.4 }
            let inner = run.filter { $0.frame.minX - leftmost >= height * 0.8 }
            let listed = outer.filter { startsLikeEntry($0.text) }.count * 2 > outer.count
            let hangs = outer.count >= 2 && !inner.isEmpty && (inner.count > outer.count || (inner.count == outer.count && listed))
            let left = hangs ? leftmost + median(inner.map { $0.frame.minX - leftmost }) : leftmost
            let shape = Shape(count: run.count, left: left, leftmost: leftmost, right: right,
                              gap: gaps.count >= 2 ? gaps[gaps.count / 4] : nil, height: height, hangs: hangs)
            result += Array(repeating: shape, count: run.count)
            start = end
        }
        for i in 1..<max(lines.count, 1) where !continuesColumn(lines[i - 1], lines[i]) { close(i) }
        if !lines.isEmpty { close(lines.count) }
        return result
    }

    /// Whether `next` is the line below `line` in the same column of the same page.
    private static func continuesColumn(_ line: Line, _ next: Line) -> Bool {
        guard line.page == next.page, next.frame.maxY <= line.frame.midY else { return false }
        return next.frame.minX < line.frame.maxX && line.frame.minX < next.frame.maxX
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", ":", "。", "？", "！", "：", "\"", "”", "’", ")", "）"]

    /// Whether a line finishes a sentence, looking past a reference to sources after the full stop
    /// (activity.[57], activity.43, activity.⁴³).
    static func endsSentence(_ text: String) -> Bool {
        var core = Substring(text)
        if core.last == "]", let open = core.lastIndex(of: "["),
           core[core.index(after: open)..<core.index(before: core.endIndex)].allSatisfy({ $0.isNumber || ",–-  ".contains($0) }) {
            core = core[..<open]
        }
        let superscripts = "⁰¹²³⁴⁵⁶⁷⁸⁹"
        core = core.reversed().drop { $0.isNumber || superscripts.contains($0) || ",–-".contains($0) }.reversed().reduce(into: Substring()) { $0.append($1) }
        guard let last = core.last else { return false }
        return sentenceEnds.contains(last)
    }

    /// Whether a line ends on an abbreviation rather than a sentence: J., Nat., Commun., Soc., et al.
    static func endsOnAbbreviation(_ text: String) -> Bool {
        guard text.last == "." else { return false }
        let word = text.dropLast().reversed().prefix { !$0.isWhitespace && $0 != "," && $0 != "." }.reversed()
        let letters = String(word)
        guard !letters.isEmpty, letters.allSatisfy({ $0.isLetter }) else { return false }
        if ["al", "etc", "eq", "eqs", "fig", "figs", "ref", "refs", "vol", "no", "pp", "ed", "eds", "ca", "cf", "vs"].contains(letters.lowercased()) { return true }
        return letters.count <= 7 && letters.first?.isUppercase == true
    }

    private static func paragraphEnds(between i: Int, and j: Int, in lines: [Line], shapes: [Shape]) -> Bool {
        let line = lines[i], next = lines[j], shape = shapes[i]
        let h = shape.height
        let endsSentence = CleanCopy.endsSentence(line.text)
        // Stops well short of where the column's full lines end.
        let short = shape.right - line.frame.maxX > h * 2
        guard continuesColumn(line, next) else {
            // At the bottom of a column or page the paragraph carries on, unless this line plainly
            // ended it. That needs enough lines to know where full lines end.
            return endsSentence && short && shape.count >= 3
        }
        // The number of the next entry standing on a line of its own, after a finished one.
        if endsSentence && isEntryMarker(next.text) { return true }
        // More space than usual between the lines. With too few lines to know the usual spacing
        // (a double-spaced typescript has wide spacing everywhere), only a very wide gap counts.
        let gap = line.frame.minY - next.frame.maxY
        if let usual = shape.gap { if gap > usual + h * 0.6 { return true } } else if gap > h * 1.6 { return true }
        // A heading: a short line in larger type than the text under it. (A full line can be taller
        // than its neighbours only because of a superscript, which is no reason to break.)
        if line.frame.height > next.frame.height * 1.12 && short { return true }
        if shape.hangs {
            // References and lists: an entry starts at the left edge, its later lines are set in.
            if next.frame.minX - shape.leftmost < h * 0.4 { return true }
        } else {
            // Paragraphs whose first line is set in, after a line that finished a sentence. (A single
            // reference whose later lines are set in does not finish one at its first line.)
            // A line ending on an abbreviation (J., Nat. Commun.) finishes one only if it is also short.
            if next.frame.minX - shape.left > h * 0.8 && line.frame.minX - shape.left < h * 0.4 && endsSentence
                && (!endsOnAbbreviation(line.text) || short) { return true }
        }
        return endsSentence && short && shape.count >= 3
    }

    // MARK: Joining

    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FFFF: return true
        default: return false
        }
    }

    /// Letters of the Latin alphabet, with or without accents; not Greek (α-helix keeps its hyphen).
    private static func isLatin(_ character: Character) -> Bool {
        guard character.isLetter, let scalar = character.unicodeScalars.first else { return false }
        return scalar.isASCII || (0x00C0...0x024F).contains(scalar.value)
    }

    private static let breakHyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}"]
    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}"]

    /// A line that ends in a hyphen between a letter and a lowercase letter is a word carrying on,
    /// never the end of a paragraph.
    private static func continuesWord(_ text: String, _ next: String) -> Bool {
        guard let last = text.last, breakHyphens.contains(last), text.dropLast().last?.isLetter == true else { return false }
        return next.first.map { $0.isLetter && $0.isLowercase } ?? false
    }

    private static func joined(_ text: String, _ next: String, isWord: (String) -> Bool) -> String {
        var text = text
        // A dash at the end of the line after a letter, digit or closing bracket, before a letter or
        // digit (MoS2-|based, Fe(III)-|containing, 10–|20, effect—|which): no space. A hyphen goes
        // only where it merely split a word in two.
        if let last = text.last, dashes.contains(last), let before = text.dropLast().last,
           before.isLetter || before.isNumber || before == ")" || before == "]",
           let first = next.first, first.isLetter || first.isNumber {
            if breakHyphens.contains(last), first.isLowercase, isLatin(before) {
                let head = String(text.dropLast().reversed().prefix { $0.isLetter }.reversed())
                let tail = String(next.prefix { $0.isLetter })
                if head.count >= 2, head.allSatisfy(isLatin), tail.allSatisfy(isLatin), isWord(head + tail) {
                    text.removeLast()
                }
            }
            return text + next
        }
        if isCJK(text.last) || isCJK(next.first) { return text + next }
        return text + " " + next
    }
}
