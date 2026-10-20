import CoreGraphics
import Foundation
import PDFKit

/// An outline worked out from a document's text, for documents that carry none: the headings of its
/// sections, found by the type they are set in, how they are numbered, and the words sections are
/// usually called by.
///
/// Reading a whole document's text costs memory the system does not give back, so the reader runs
/// this in a process of its own that exits once it has answered (see `OutlineProcess`).
public enum OutlineDecoder {
    /// One heading found.
    public struct Heading: Equatable {
        public let title: String
        public let depth: Int
        public let page: Int
        /// Where the heading starts in its page's text.
        public let offset: Int
        /// The top-left corner of its first line, in page coordinates.
        public let point: CGPoint
    }

    /// At most this many pages are read.
    static let pageLimit = 150

    /// The document's outline as the sidebar shows it. Empty when no headings were found that can
    /// be trusted.
    public static func entries(of document: PDFDocument) -> [OutlineEntry] {
        let found = headings(of: document)
        return found.enumerated().map { i, heading in
            OutlineEntry(title: heading.title, depth: heading.depth, page: heading.page, point: heading.point,
                         hasChildren: i + 1 < found.count && found[i + 1].depth > heading.depth)
        }
    }

    /// A piece of a line of text in one type: a whole line, or the part of it in a type of its own
    /// (a running head and a heading can come out as one line).
    struct Line {
        let page: Int
        let offset: Int
        let text: String
        let rect: CGRect
        let size: CGFloat
        let font: String
        /// How much of the line's text is in the running text's own font.
        var bodyShare: CGFloat = 0
        /// Where the line (the last of them, for a heading over several lines) is among all lines read.
        var index = 0
        var style: String { "\(font) \(Int((size * 2).rounded()))" }
        var bold: Bool { PageFonts.isBold(font) }
        var italic: Bool { PageFonts.isItalic(font) }
    }

    /// Names sections are usually given; a heading reading only one of these is a heading whatever
    /// its type. Compared by their letters alone, so that text that lost its spaces ("ConflictofInterest")
    /// or a ligature ("Con icts of interest") still matches.
    private static let referenceNames = ["references", "references and notes", "notes and references", "bibliography", "literature cited", "参考文献"]
    private static let sectionNames = referenceNames + [
        "abstract", "introduction", "result", "results", "discussion", "results and discussion", "results and discussions",
        "conclusion", "conclusions", "concluding remarks", "summary", "summary and outlook", "conclusion and outlook",
        "conclusions and outlook", "outlook", "method", "methods", "materials and methods", "experimental", "experimental section",
        "experimental details", "experimental methods", "computational details", "computational method", "computational methods",
        "theory", "acknowledgement", "acknowledgements", "acknowledgment", "acknowledgments", "conflict of interest",
        "conflicts of interest", "competing interest", "competing interests", "declaration of competing interest",
        "author contributions", "data availability", "data availability statement", "supporting information",
        "supplementary information", "supplementary material", "electronic supplementary information", "keywords",
        "appendix", "funding", "additional information", "摘要", "引言", "前言", "结论", "致谢"]
    private static func letterKeys(_ names: [String]) -> Set<String> {
        var keys = Set<String>()
        for name in names {
            let key = name.filter(\.isLetter)
            keys.insert(key)
            // The same with a ligature's letters lost.
            for ligature in ["ffi", "ffl", "fi", "fl", "ff"] where key.contains(ligature) { keys.insert(key.replacingOccurrences(of: ligature, with: "")) }
        }
        return keys
    }
    private static let sectionKeys = letterKeys(sectionNames)
    private static let referenceKeys = letterKeys(referenceNames)
    /// Section numbers: "2 ", "2.", "2.3", "2.3.1.", "IV.", "III.A", "B.", followed by a word ("0D…" too).
    /// A number run straight into letters is part of a word ("2D materials").
    private static let numbering = try! NSRegularExpression(pattern: #"^(?:(\d{1,2}(?:\.\d{1,2}){0,3})(?:\.\s?|\s)|([IVX]{1,5})\.(?:([A-H])\.?)?\s?|([A-H])\.\s?)(?=[\p{L}(]|\d[\p{L}])"#)

    public static func headings(of document: PDFDocument) -> [Heading] {
        // A book or thesis is beyond what these rules were made for.
        guard document.pageCount <= pageLimit else { return [] }
        let lines = readLines(of: document)
        guard !lines.isEmpty else { return [] }
        // The running text's type: the most common font and size, by amount of text.
        var amounts: [String: Int] = [:]
        for line in lines { amounts[line.style, default: 0] += line.text.count }
        guard let bodyStyle = amounts.max(by: { $0.value < $1.value })?.key,
              let body = lines.first(where: { $0.style == bodyStyle }) else { return [] }
        let repeated = runningHeads(lines, document: document)
        let contents = contentsBox(lines, bodyStyle: bodyStyle)

        // Lines set apart from the running text: a point larger or more, or bold, or italic, and short.
        // Headings may be a little smaller than the running text, when bold ("I. INTRODUCTION" at 9
        // points over text at 10), or in a font of their own that is not named bold, when they are
        // a section's usual name. Not lines of a table of contents, a reference or an address.
        let candidates = lines.filter { line in
            guard line.style != bodyStyle, line.size >= body.size * 0.85, line.bodyShare < 0.25 else { return false }
            let letters = line.text.filter(\.isLetter).count
            guard letters >= 3, line.text.count <= 160, !repeated.contains(normalized(line.text)),
                  !contents.contains(line.index), !looksLikeReferenceOrAddress(line.text) else { return false }
            if line.text.range(of: #"^(?:Fig(?:ure)?s?\.?|Table|Scheme|Chart)\s*\d"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
            if line.font != body.font && isSectionWord(line.text) { return true }
            if line.size >= body.size + 1 { return true }
            return line.size >= body.size - 0.6 ? line.bold || line.italic : line.bold || line.italic && number(of: line.text) != nil
        }
        // Lines that follow on from the one before: the second line of a long heading, even one that
        // reads as a section's name ("Density Functional⏎Theory").
        var merged: [Line] = []
        for line in candidates {
            if let last = merged.last, last.page == line.page, last.style == line.style, number(of: line.text) == nil,
               !isSectionWord(last.text), abs(last.rect.minX - line.rect.minX) < 12 || abs(last.rect.midX - line.rect.midX) < 12
                || number(of: last.text) != nil && line.rect.minX > last.rect.minX && line.rect.minX - last.rect.minX < 30,
               last.rect.minY - line.rect.maxY < line.size * 0.9, line.rect.maxY <= last.rect.minY + 2 {
                merged[merged.count - 1] = Line(page: last.page, offset: last.offset, text: joined(last.text, line.text),
                                                rect: last.rect.union(line.rect), size: last.size, font: last.font, bodyShare: last.bodyShare,
                                                index: line.index)
                continue
            }
            merged.append(line)
        }

        // The top level: the type with the most lines that are section words or top-level numbers.
        var groups: [String: [Line]] = [:]
        for line in merged { groups[line.style, default: []].append(line) }
        func topScore(_ group: [Line]) -> Int {
            group.filter { isSectionWord($0.text) || number(of: $0.text).map { $0.parts.count == 1 || $0.roman && $0.letter == nil } == true }.count
        }
        guard let top = groups.filter({ topScore($0.value) >= 2 })
            .max(by: { (topScore($0.value), $0.value[0].size) < (topScore($1.value), $1.value[0].size) })?.value else { return [] }
        let topStyle = top[0].style
        // Numbered with Roman numerals when the top level has two or more of those and its first numbered
        // heading is one ("I. INTRODUCTION"); the Arabic numbers are then a lower level, even where they
        // are more and set in the same type.
        let romanTop = top.filter { number(of: $0.text).map { $0.roman && $0.letter == nil } ?? false }.count
        let firstNumbered = top.filter { number(of: $0.text).map { $0.parts.count == 1 || $0.roman && $0.letter == nil } ?? false }
            .min { ($0.page, $0.offset) < ($1.page, $1.offset) }
        let roman = romanTop >= 2 && (firstNumbered.flatMap { number(of: $0.text) }?.roman ?? false)
        let topNumbered = top.filter { number(of: $0.text) != nil }.count * 2 >= top.filter { !isSectionWord($0.text) }.count && top.contains { number(of: $0.text) != nil }

        // Where the paper starts (its first numbered or usually named top-level heading) and where its
        // text ends (its reference list): before the one, and after the other, only section names count.
        guard let firstTop = top.filter({ isSectionWord($0.text) && !frontMatter(of: $0.text) || number(of: $0.text) != nil })
            .min(by: { ($0.page, $0.offset) < ($1.page, $1.offset) }) else { return [] }
        let referencesStart = merged.filter { referenceKeys.contains(key(of: $0.text)) && ($0.page, $0.offset) > (firstTop.page, firstTop.offset) }
            .map { ($0.page, $0.offset) }.min { $0 < $1 }

        var found: [(heading: Heading, number: Number?, line: Line)] = []
        // The lower level that is not numbered: a type of its own, between top-level headings.
        var unnumberedStyles: [String: Int] = [:]
        if !topNumbered {
            let lower = groups.filter { style, group in
                style != topStyle && group.count >= 2 && group[0].size <= top[0].size + 0.1
                    && (group[0].bold || group[0].size >= body.size + 1) && group.allSatisfy { number(of: $0.text) == nil }
                    && Set(group.map(\.page)).count >= 2 && group.filter { isSectionWord($0.text) }.count * 2 < group.count
            }
            if let style = lower.max(by: { ($0.value[0].size, $0.value[0].bold ? 1 : 0) < ($1.value[0].size, $1.value[0].bold ? 1 : 0) })?.key {
                unnumberedStyles[style] = 1
            }
        }
        for line in merged {
            let text = plain(line.text)
            let afterReferences = referencesStart.map { (line.page, line.offset) > $0 } ?? false
            let beforeStart = (line.page, line.offset) < (firstTop.page, firstTop.offset)
            let n = number(of: text)
            var depth: Int?
            if isSectionWord(text) && (n == nil || n!.parts.count == 1 && !roman || n!.roman && n!.letter == nil) {
                // A section's name heads a section only where the paper's text is, or for the abstract
                // and keywords before it, and with text after it (not a label in a figure's legend).
                let isReferences = referenceKeys.contains(key(of: text))
                if beforeStart && !frontMatter(of: text) { continue }
                if n == nil && !isReferences && !frontMatter(of: text) && !followedByText(line, in: lines) { continue }
                depth = 0
            } else if afterReferences || beforeStart {
                continue
            } else if let n {
                guard titleReadsLikeOne(text, numbered: true) else { continue }
                if n.letter != nil && !n.roman && !roman { continue }
                // Under Roman numerals an Arabic number needs its full stop ("1. Performance…", not
                // "31 Numerical Data…").
                if roman && !n.roman && n.letter == nil && !text.hasPrefix("\(n.parts.map(String.init).joined(separator: ".")).") { continue }
                if !roman && n.roman { continue }
                depth = roman ? n.romanDepth : n.depth
                // A top-level number in the top level's own type, or one as large and as bold: not the
                // numbered points of a lower level whose own top level was not found ("1. The TKNN invariant").
                if depth == 0, line.style != topStyle, !(line.size >= top[0].size - 0.3 && line.bold == top[0].bold) { continue }
            } else if line.style == topStyle && !topNumbered, titleReadsLikeOne(text, numbered: false), looksLikeHeading(line, in: lines, bodyStyle: bodyStyle) {
                depth = 0
            } else if let level = unnumberedStyles[line.style], titleReadsLikeOne(text, numbered: false), looksLikeHeading(line, in: lines, bodyStyle: bodyStyle) {
                depth = level
            }
            guard let depth, !line.text.hasSuffix(".") || n != nil && text.count < 8 else { continue }
            found.append((Heading(title: text, depth: depth, page: line.page, offset: line.offset, point: CGPoint(x: line.rect.minX, y: line.rect.maxY)), n, line))
        }
        found.sort { ($0.heading.page, column($0.heading, document), -$0.heading.point.y, $0.heading.offset)
            < ($1.heading.page, column($1.heading, document), -$1.heading.point.y, $1.heading.offset) }
        // The same name, or the same number where numbers are not used again (letters and the numbers
        // under them are, under each Roman numeral), more than once: the one running text follows (a
        // table of contents has none), or the first of a heading and its translation set right under it,
        // or failing those the last.
        func label(_ item: (heading: Heading, number: Number?, line: Line)) -> String {
            guard let n = item.number else { return "=" + key(of: item.heading.title) }
            if roman && !(n.roman && n.letter == nil) { return "unique\(item.heading.page)-\(item.heading.offset)" }
            return "#" + n.label
        }
        var kept: [(heading: Heading, number: Number?, line: Line)] = []
        var seen = Set<String>()
        for item in found where !seen.contains(label(item)) {
            let same = found.filter { label($0) == label(item) }
            seen.insert(label(item))
            guard same.count > 1 else { kept.append(item); continue }
            let translated = same.first { a in same.contains { b in b.line.index > a.line.index && b.line.index <= a.line.index + 3 && b.heading.page == a.heading.page } }
            kept.append(translated ?? same.first { followedByText($0.line, in: lines) } ?? same.last!)
        }
        found = numberedInSequence(kept.sorted { ($0.heading.page, column($0.heading, document), -$0.heading.point.y, $0.heading.offset)
            < ($1.heading.page, column($1.heading, document), -$1.heading.point.y, $1.heading.offset) }, roman: roman)
        // Depths as levels shown: no level deeper than one below the one before.
        var previous = -1
        let headings = found.map { item -> Heading in
            let depth = min(item.heading.depth, previous + 1)
            previous = depth
            return Heading(title: item.heading.title, depth: depth, page: item.heading.page, offset: item.heading.offset, point: item.heading.point)
        }
        return headings.count >= 2 ? headings : []
    }

    /// Keeps numbered headings only where their numbers follow on, in the order they come: each top-level
    /// number one or two more than the last, starting at 1 or 2; each lower one under the number above it
    /// and one or two more than its sibling before. Under Roman numerals, letters (A., B.) and then Arabic
    /// numbers (1., 2.) are the lower levels; an "I." where the letters have reached H. is the letter I.
    private static func numberedInSequence(_ found: [(heading: Heading, number: Number?, line: Line)], roman: Bool) -> [(heading: Heading, number: Number?, line: Line)] {
        var path: [Int] = []          // the numbers of the heading last kept, by level
        func follows(_ value: Int, at level: Int) -> Bool {
            let last = path.count > level ? path[level] : 0
            // The top level starts at 1; a lower one may start at 2 when its first heading was missed.
            return value == last + 1 || value == last + 2 && last > 0 || (last == 0 && level > 0 && value == 2)
        }
        func keep(_ value: Int, at level: Int) {
            path = Array(path.prefix(level)) + [value]
        }
        return found.filter { item in
            guard var n = item.number else { return true }
            if roman {
                // "I." after "H.": the ninth letter, not a numeral.
                if n.roman, n.letter == nil, let only = n.romanSingleLetter, path.count >= 2, path[1] + 1 == only {
                    n = Number(parts: [], roman: false, letter: Character(UnicodeScalar(64 + only)!), arabic: nil, romanValue: nil)
                }
                if n.roman {
                    guard let value = n.romanValue else { return false }
                    if let letter = n.letterIndex {
                        guard path.first == value, follows(letter, at: 1) else { return false }
                        keep(letter, at: 1)
                    } else {
                        guard follows(value, at: 0) else { return false }
                        keep(value, at: 0)
                    }
                    return true
                }
                if let letter = n.letterIndex {
                    guard !path.isEmpty, follows(letter, at: 1) else { return false }
                    keep(letter, at: 1)
                    return true
                }
                guard path.count >= 2, n.parts.count == 1, follows(n.parts[0], at: 2) else { return false }
                keep(n.parts[0], at: 2)
                return true
            }
            guard !n.parts.isEmpty else { return false }
            let level = n.parts.count - 1
            guard Array(n.parts.prefix(level)) == Array(path.prefix(level)), path.count >= level, follows(n.parts[level], at: level) else { return false }
            keep(n.parts[level], at: level)
            return true
        }
    }

    /// Section names that come before the paper's text and may stand there.
    private static func frontMatter(of text: String) -> Bool {
        ["abstract", "keywords", "摘要"].contains(key(of: text))
    }

    /// Whether running text, of whatever size, follows a line: the next line, just below it, written
    /// out at some length (not a legend's next label) — or the line after a short one under it (a
    /// subsection's heading, or the heading in a second language).
    private static func followedByText(_ line: Line, in lines: [Line]) -> Bool {
        var above = line
        for step in 1...2 {
            guard line.index + step < lines.count, lines[line.index + step].page == line.page else { return false }
            let next = lines[line.index + step]
            guard next.rect.maxY <= above.rect.minY + 2, above.rect.minY - next.rect.maxY < max(above.size, next.size) * 2.5 else { return false }
            if next.text.filter(\.isLetter).count >= 20 { return true }
            // Looked past only when it is a heading itself (bold, or as large), not a legend's figures.
            guard next.text.filter(\.isLetter).count >= 2, next.bold || next.size >= line.size - 0.5 else { return false }
            above = next
        }
        return false
    }

    /// Whether a heading's words read like a title: not a formula ("2 fc rij (4)", math set in its own
    /// letters, a measured value "0.06 Å"), not a sentence or the start of one ("A. Both the … were",
    /// "…Version 3. When new"), not a row of a table ("Cu3 122 ± 8"), not a name's initials ("F. C. Chou").
    private static func titleReadsLikeOne(_ text: String, numbered: Bool) -> Bool {
        let ns = text as NSString
        let title = numbered ? (numbering.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(from: $0.range.length) } ?? text) : text
        guard title.range(of: #"\p{Lu}\p{L}{2}"#, options: .regularExpression) != nil || !numbered,
              title.range(of: #"\(\d+\)$"#, options: .regularExpression) == nil,
              !title.unicodeScalars.contains(where: { (0x1D400...0x1D7FF).contains($0.value) }),
              title.range(of: #"\d\.\d"#, options: .regularExpression) == nil,
              title.range(of: #"\s(?:is|are|was|were|has|have)$"#, options: .regularExpression) == nil,
              title.range(of: #"[\p{L}\d)\]]\.\s?\p{Lu}\p{Ll}|\p{Ll}{2}\.\s+\p{Lu}|[;；。]"#, options: .regularExpression) == nil,
              !title.contains("±"),
              title.split(separator: " ").filter({ $0.allSatisfy { $0.isNumber || $0 == "." || $0 == "," } && $0.contains(where: \.isNumber) }).count < 2,
              title.range(of: #"^\p{Lu}\.\s?\p{Lu}\.|^\p{Lu}\.\s\p{Lu}[\p{Ll}]+,"#, options: .regularExpression) == nil else { return false }
        if numbered, let first = title.split(separator: " ").first.map(String.init), sentenceStarts.contains(first), title.split(separator: " ").count > 6 { return false }
        return true
    }

    /// Words that start sentences rather than headings, when a long line starts with them.
    private static let sentenceStarts: Set<String> = ["This", "These", "That", "There", "It", "We", "Our", "However", "Thus", "Here", "In", "As", "For", "The"]

    /// A reference, an author's address or the like: no heading.
    private static func looksLikeReferenceOrAddress(_ text: String) -> Bool {
        text.range(of: #"\bet al\.|\b(?:19|20)\d\d\b.*\b\d+\b|\bdoi\b|\bUniversity\b|\bUniversität\b|\bInstitute\b|\bDepartment\b|\bLaboratory\b|\bCollege\b|\bSchool of\b|\bAcademy\b|@|\bJ\. [A-Z]|\bPhys\. Rev\.|\bChem\. Soc\.|大学|研究所|学院"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The lines of a table of contents: those after a line reading "Contents", on its page, in the
    /// types its first few entries are set in — up to where the running text, or a heading, comes.
    private static func contentsBox(_ lines: [Line], bodyStyle: String) -> Set<Int> {
        var inside = Set<Int>()
        for line in lines where ["contents", "tableofcontents", "目录"].contains(normalized(line.text)) {
            let entries = Set(lines[(line.index + 1)...].prefix(3).filter { $0.page == line.page }.map(\.style))
            var i = line.index + 1
            while i < lines.count, lines[i].page == line.page, lines[i].style != bodyStyle, entries.contains(lines[i].style) {
                inside.insert(i)
                i += 1
            }
        }
        return inside
    }

    /// Which column of its page a heading is in: 0 for the left or a heading across the page, 1 for the right.
    private static func column(_ heading: Heading, _ document: PDFDocument) -> Int {
        guard let page = document.page(at: heading.page) else { return 0 }
        let box = page.bounds(for: .cropBox)
        return heading.point.x > box.midX - 10 ? 1 : 0
    }

    struct Number {
        let parts: [Int]
        let roman: Bool
        let letter: Character?
        let arabic: Int?
        var romanValue: Int? = nil
        var depth: Int { roman ? (letter == nil ? 0 : 1) : (letter != nil ? 1 : parts.count - 1) }
        /// Under Roman numerals: "A." one below, "1." two below.
        var romanDepth: Int { roman ? depth : (letter != nil ? 1 : (parts.count == 1 ? 2 : parts.count)) }
        /// A, B, C… as 1, 2, 3….
        var letterIndex: Int? { letter.flatMap { $0.asciiValue }.map { Int($0) - 64 } }
        /// A numeral that is one letter (I, V, X), as the position of that letter in the alphabet.
        var romanSingleLetter: Int? {
            guard roman, letter == nil, let value = romanValue, [1, 5, 10].contains(value) else { return nil }
            return ["I": 9, "V": 22, "X": 24][value == 1 ? "I" : value == 5 ? "V" : "X"]
        }
        /// The number as written, to tell two headings with the same number apart from others.
        var label: String { roman ? "\(romanValue ?? 0)\(letter.map(String.init) ?? "")" : letter.map(String.init) ?? parts.map(String.init).joined(separator: ".") }
    }

    static func number(of text: String) -> Number? {
        let ns = text as NSString
        guard let m = numbering.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        if m.range(at: 1).location != NSNotFound {
            let parts = ns.substring(with: m.range(at: 1)).split(separator: ".").compactMap { Int($0) }
            guard parts.allSatisfy({ $0 > 0 && $0 <= 30 }) else { return nil }
            return Number(parts: parts, roman: false, letter: nil, arabic: parts.first)
        }
        if m.range(at: 2).location != NSNotFound {
            let letter = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)).first : nil
            return Number(parts: [], roman: true, letter: letter, arabic: nil, romanValue: romanNumber(ns.substring(with: m.range(at: 2))))
        }
        return Number(parts: [], roman: false, letter: ns.substring(with: m.range(at: 4)).first, arabic: nil)
    }

    static func romanNumber(_ s: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10]
        var total = 0, largest = 0
        for c in s.reversed() {
            guard let v = values[c] else { return nil }
            total += v < largest ? -v : v
            largest = max(largest, v)
        }
        return total > 0 ? total : nil
    }

    static func isSectionWord(_ text: String) -> Bool { sectionKeys.contains(key(of: text)) }

    /// A heading's letters alone, lower-cased, after its number.
    private static func key(of text: String) -> String {
        var t = plain(text)
        if let m = numbering.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) { t = (t as NSString).substring(from: m.range.length) }
        // A section's name has no figures in it ("10. 11. 12. … Data availability" is a column of
        // reference numbers run into a heading).
        guard !t.contains(where: \.isNumber) else { return "" }
        return t.lowercased().filter(\.isLetter)
    }

    /// An unnumbered line that is no section name counts as a heading only when it reads like one
    /// and running text follows it: not text inside a figure ("Energy (eV)"), the rest of a line
    /// above ("as Activity Descriptor") or a sentence.
    private static func looksLikeHeading(_ line: Line, in lines: [Line], bodyStyle: String) -> Bool {
        let text = plain(line.text)
        guard let first = text.first(where: { $0.isLetter || $0.isNumber }), !first.isLowercase, !text.hasSuffix("-"),
              text.range(of: #"\p{L}{4}"#, options: .regularExpression) != nil,
              text.range(of: #"[.。;；，]\s*\S"#, options: .regularExpression) == nil else { return false }
        // Type is set so that a heading never ends a page or column; nothing after it on its page means
        // it is none.
        guard line.index + 1 < lines.count, lines[line.index + 1].page == line.page else { return false }
        let next = lines[line.index + 1]
        return next.style == bodyStyle && next.rect.maxY <= line.rect.minY + 2 && line.rect.minY - next.rect.maxY < line.size * 2.5
            && abs(next.rect.minX - line.rect.minX) < 40
    }

    static func plain(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FB01}", with: "fi").replacingOccurrences(of: "\u{FB02}", with: "fl")
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter }
    }

    private static func joined(_ a: String, _ b: String) -> String {
        a.hasSuffix("-") ? String(a.dropLast()) + b : a + " " + b
    }

    /// Text that recurs at the top or foot of several pages, in the same place: running heads, journal
    /// names, page numbers.
    private static func runningHeads(_ lines: [Line], document: PDFDocument) -> Set<String> {
        var pages: [String: Set<Int>] = [:]
        for line in lines {
            guard let page = document.page(at: line.page) else { continue }
            let box = page.bounds(for: .cropBox)
            guard line.rect.minY > box.maxY - box.height * 0.1 || line.rect.maxY < box.minY + box.height * 0.08 else { continue }
            pages[normalized(line.text) + " \(Int((line.rect.midY / 6).rounded()))", default: []].insert(line.page)
        }
        // On two pages is enough: no heading is written twice in the same place on a page.
        return Set(pages.filter { !$0.key.hasPrefix(" ") && $0.value.count >= 2 }.keys.map { String($0.split(separator: " ")[0]) })
    }

    /// Every line of the document's text, split where the type size changes, with the font each is set in.
    static func readLines(of document: PDFDocument) -> [Line] {
        var read: [(line: Line, fonts: [String: Int])] = []
        var fontAmounts: [String: Int] = [:]
        for p in 0..<min(document.pageCount, pageLimit) {
            guard let page = document.page(at: p), let attributed = page.attributedString else { continue }
            let runs = PageFonts.runs(of: page)
            for run in runs { fontAmounts[run.font, default: 0] += run.length }
            let text = attributed.string as NSString
            var start = 0
            while start < text.length {
                let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start)).location
                let end = newline == NSNotFound ? text.length : newline
                for piece in pieces(of: attributed, from: start, to: end) {
                    let range = NSRange(location: piece.start, length: piece.end - piece.start)
                    guard let rect = page.selection(for: range)?.bounds(for: page), rect.width > 0 else { continue }
                    var fonts: [String: Int] = [:]
                    let onLine = runs.filter { $0.origin.y >= rect.minY - 2 && $0.origin.y <= rect.maxY + 1 }
                    for run in onLine where run.origin.x >= rect.minX - 3 && run.origin.x <= rect.maxX + 1 {
                        fonts[run.font, default: 0] += run.length
                    }
                    // No piece of text starts inside it: it goes on from the last one started before it.
                    if fonts.isEmpty, let last = onLine.filter({ $0.origin.x < rect.minX }).max(by: { $0.origin.x < $1.origin.x }) {
                        fonts[last.font] = last.length
                    }
                    guard let font = fonts.max(by: { $0.value < $1.value })?.key else { continue }
                    read.append((Line(page: p, offset: piece.start, text: text.substring(with: range).trimmingCharacters(in: .whitespaces),
                                      rect: rect, size: piece.size, font: font), fonts))
                }
                start = end + 1
            }
        }
        // How much of each line is in the document's main font, once that is known.
        let main = fontAmounts.max { $0.value < $1.value }?.key ?? ""
        return read.enumerated().map { i, item in
            var line = item.line
            line.index = i
            let total = item.fonts.values.reduce(0, +)
            line.bodyShare = total > 0 && line.font != main ? CGFloat(item.fonts[main] ?? 0) / CGFloat(total) : 0
            return line
        }
    }

    /// A line split where the type size changes by a point or more and stays changed for three
    /// letters or more (a running head joined to a heading), not at a subscript or a raised mark.
    private static func pieces(of attributed: NSAttributedString, from start: Int, to end: Int) -> [(start: Int, end: Int, size: CGFloat)] {
        guard end > start else { return [] }
        let text = attributed.string as NSString
        func size(_ k: Int) -> CGFloat { (attributed.attribute(.font, at: k, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        func isLetter(_ k: Int) -> Bool { UnicodeScalar(text.character(at: k)).map { CharacterSet.letters.contains($0) } ?? false }
        var cuts: [(at: Int, size: CGFloat)] = []
        for k in start..<end where isLetter(k) {
            let here = size(k)
            guard let current = cuts.last?.size else { cuts.append((start, here)); continue }
            guard abs(here - current) >= 1 else { continue }
            var letters = 0, j = k
            while j < end, letters < 3 {
                if isLetter(j) { if abs(size(j) - here) < 0.5 { letters += 1 } else { break } }
                j += 1
            }
            guard letters >= 3 else { continue }
            var cut = k
            while cut > (cuts.last?.at ?? start), text.character(at: cut - 1) != 32 { cut -= 1 }
            // A section number before the word, in the same size, goes with it ("Perspective | 1. Introduction").
            var before = cut - 1
            while before > cuts.last!.at, text.character(at: before) == 32 { before -= 1 }
            var token = before
            while token > cuts.last!.at, text.character(at: token - 1) != 32 { token -= 1 }
            if before > token || before == token, before >= cuts.last!.at,
               text.substring(with: NSRange(location: token, length: before - token + 1)).allSatisfy({ $0.isNumber || $0 == "." }),
               abs(size(token) - here) < 0.5, token > cuts.last!.at { cut = token }
            if cut > cuts.last!.at { cuts.append((cut, here)) } else { cuts[cuts.count - 1].size = here }
        }
        guard !cuts.isEmpty else { return [(start, end, size(start))] }
        return cuts.enumerated().map { i, cut in (cut.at, i + 1 < cuts.count ? cuts[i + 1].at : end, cut.size) }
    }
}
