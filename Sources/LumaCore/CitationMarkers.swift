import CoreGraphics
import Foundation
import PDFKit

/// A citation in the text of a page: where it is and the reference entries it names.
public struct CitationMarker: Equatable {
    public let page: Int
    /// In the page's own coordinates.
    public let rect: CGRect
    /// The entries, in order; a range such as 14–25 names every entry in it.
    public let numbers: [Int]
    /// Each number written in the marker, with its own rectangle, so that the one under the pointer
    /// is the one shown. The numbers inside a range have none.
    public let parts: [(number: Int, rect: CGRect)]
    /// Where it is in the page's text.
    public let range: NSRange

    public static func == (a: CitationMarker, b: CitationMarker) -> Bool {
        a.page == b.page && a.rect == b.rect && a.numbers == b.numbers
    }
}

/// Finds numbered citations in the text of a page.
///
/// Three forms are read: numbers in square brackets ("[12]", "[3, 5–7]", in any type size), raised
/// small numbers ("…electrodes.²⁻¹⁰"), and citations written out ("ref. 43"). Raised small numbers
/// are also exponents, charges, isotopes and affiliation marks; these are told apart by what stands
/// next to them. Only numbers that name entries the reference list has count: a marker with any
/// number the list does not have is left alone.
public enum CitationMarkers {
    private static let baselineKey = NSAttributedString.Key("CTBaselineOffset")
    private static let written = try! NSRegularExpression(
        pattern: #"\b[Rr]efs?\.?\s*\[?\d{1,3}(?:\s*[–−-]\s*\d{1,3})?(?:\s*(?:,|and)\s*\d{1,3}(?:\s*[–−-]\s*\d{1,3})?)*\]?"#)
    /// Units of length, squared or cubed by a small 2 or 3 ("cm2", "Å3", "g/cm3").
    private static let units: Set<String> = ["cm", "mm", "nm", "μm", "m", "km", "dm", "Å"]
    /// Orbitals and the like, whose small numbers are part of the name ("sp2", "dz2", "2s2").
    private static let orbital = try! NSRegularExpression(pattern: #"(?:^|[^A-Za-z])(?:sp|dz|dx|dy|[spdf])$|\d[spdf]$|x\d?-y$"#)
    /// A person's name, as in an author line: "Tanaka," before an affiliation mark.
    private static let personName = try! NSRegularExpression(pattern: #"^[A-Z][\p{Ll}'’\-]*[\p{Ll}][,.]?$|^[A-Z][\p{Ll}]+-[a-z]-[A-Z][\p{Ll}]+[,.]?$"#)

    /// The forms of citation looked for.
    public enum Kind: CaseIterable { case brackets, raised, written }

    /// The citations on a page, before `endOffset` of its text if given, naming entries 1…`entryCount`.
    /// `bodySize` is the type size of the document's running text; by default, the page's most common.
    public static func find(on page: PDFPage, index: Int, endOffset: Int? = nil, entryCount: Int,
                            kinds: Set<Kind> = Set(Kind.allCases), bodySize: CGFloat? = nil) -> [CitationMarker] {
        guard entryCount > 0, let attributed = page.attributedString else { return [] }
        let text = attributed.string as NSString
        let end = min(endOffset ?? text.length, text.length)
        guard end > 0 else { return [] }

        func size(_ i: Int) -> CGFloat { (attributed.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        func rise(_ i: Int) -> CGFloat { CGFloat((attributed.attribute(baselineKey, at: i, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0) }
        func char(_ i: Int) -> Character { Character(UnicodeScalar(text.character(at: i)) ?? " ") }
        func isDigit(_ i: Int) -> Bool { let c = text.character(at: i); return c >= 48 && c <= 57 }

        guard let body = bodySize ?? CitationMarkers.bodySize(of: [page]), body > 0 else { return [] }

        var found: [(range: NSRange, numbers: [Int])] = []

        // Square brackets, in any size.
        var i = kinds.contains(.brackets) ? 0 : end
        while i < end {
            guard text.character(at: i) == 91 else { i += 1; continue }   // [
            var j = i + 1
            while j < end, j - i < 60, let c = UnicodeScalar(text.character(at: j)),
                  "0123456789,–−-—; \n".unicodeScalars.contains(c) || ("a"..."h").contains(Character(c)) { j += 1 }
            if j < end, text.character(at: j) == 93, j > i + 1 {   // ]
                let inner = text.substring(with: NSRange(location: i + 1, length: j - i - 1))
                let before = text.substring(with: NSRange(location: max(0, i - 6), length: i - max(0, i - 6)))
                if let numbers = numbers(in: inner), !before.hasSuffix("Fig. "), !before.hasSuffix("Eq. "), !before.hasSuffix("eqn ") {
                    found.append((NSRange(location: i, length: j - i + 1), numbers))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }

        // Raised small numbers: smaller than the text they follow, which must be running text (of the
        // body, a caption or a table, not a title or an author line).
        i = kinds.contains(.raised) ? 0 : end
        while i < end {
            guard isDigit(i), size(i) > 0, size(i) <= body * 0.9, !found.contains(where: { NSLocationInRange(i, $0.range) }) else { i += 1; continue }
            let small = size(i) + 0.3
            // Smaller than the text just before it (in a table set in small type, the table's own
            // numbers are not raised). Looked for nearby only.
            var before = i - 1
            while before >= max(0, i - 40), char(before) == " " || char(before) == "\n" || size(before) <= small { before -= 1 }
            guard before >= max(0, i - 40), size(i) <= size(before) * 0.85 else { i += 1; continue }
            var j = i
            while j < end, size(j) <= small || char(j) == " ", let c = UnicodeScalar(text.character(at: j)),
                  "0123456789,–−-".unicodeScalars.contains(c) || c == " " { j += 1 }
            // Not ending on a separator.
            while j > i, ", –−-".contains(char(j - 1)) { j -= 1 }
            defer { i = max(j, i + 1) }
            let range = NSRange(location: i, length: j - i)
            let runText = text.substring(with: range)
            guard !runText.contains(" ") || runText.contains(","), let numbers = numbers(in: runText) else { continue }
            // Raised by the text, or put on a line of its own above the text.
            let ownLine = (i == 0 || char(i - 1) == "\n") && (j >= end || char(j) == "\n" || char(j) == ".")
            let raised = (i..<j).map(rise).max() ?? 0
            guard raised > 0.3 || (abs(raised) <= 0.3 && ownLine) else { continue }
            if ownLine && raised <= 0.3 {
                // A line of numbers above or below: the ticks of a figure's axis.
                func lineAround(_ from: Int, step: Int) -> String {
                    var a = from, b = from
                    while a + step >= 0, a + step < end, char(a + step) != "\n" { a += step }
                    if step < 0 { swap(&a, &b) }
                    return a <= b && a >= 0 && b < end ? text.substring(with: NSRange(location: a, length: b - a + 1)) : ""
                }
                let above = i >= 2 ? lineAround(i - 2, step: -1) : "", below = j + 1 < end ? lineAround(j + 1, step: 1) : ""
                let numeric = { (l: String) in !l.isEmpty && l.allSatisfy { $0.isNumber || $0 == "." || $0 == " " || $0 == "−" || $0 == "-" } }
                if numeric(above) || numeric(below) { continue }
            }
            // What follows: a space, punctuation or the end of the line, not a sign, a letter, a
            // fraction bar or a decimal point ("10.1039" in a DOI).
            if j < end {
                let next = char(j)
                if "+−–-°%/=".contains(next) || next.isLetter { continue }
                if next == ".", j + 1 < end, isDigit(j + 1) { continue }
            }
            // Right before it, a sign or a times: an exponent. A raised citation touches the word it
            // follows; a space before it marks an affiliation, an exponent whose sign was lost, or a table.
            if i > 0, "−–-×^+=]/ ".contains(char(i - 1)) { continue }
            // The text it follows, past spaces and other small type.
            var k = i - 1
            while k >= 0, char(k) == " " || char(k) == "\n" || size(k) <= small { k -= 1 }
            guard k >= 0 else { continue }
            let local = size(k)
            guard size(i) <= local * 0.85, local >= body * 0.75, local <= body * 1.2 else { continue }
            // The words after it, if any on the same line, in the same type: not an affiliation line.
            var after = j
            while after < end, char(after) == " " { after += 1 }
            if after < end, char(after).isLetter, size(after) < local * 0.88 || size(after) > local * 1.15 { continue }
            let lead = text.substring(with: NSRange(location: max(0, k - 11), length: k - max(0, k - 11) + 1))
            // Put on the next line after a word: part of a formula ("VSr" over "2"), unless the word ends a
            // clause, or a small number (an exponent) comes between, or the word is a formula's index ("(AlN)n").
            let between = text.substring(with: NSRange(location: k + 1, length: i - k - 1))
            let exponentBetween = (k + 1..<i).contains { isDigit($0) && rise($0) > 0.3 }
            if between.contains("\n"), !".,;:)".contains(char(k)), !exponentBetween,
               lead.range(of: #"\)[a-z]$"#, options: .regularExpression) == nil { continue }
            let word = lead.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "(" }).last.map(String.init) ?? ""
            if char(k) == "−" || char(k) == "–" || char(k) == "-" || char(k) == "×" { continue }
            // A unit squared or cubed ("cm2", also "g/cm3"), a power of ten, or a single letter (a variable:
            // "x2", "k3", "(1−v2)"). Not when an exponent comes between: then the number follows the exponent.
            var letters = 0, m = k
            while m >= 0, char(m).isLetter { letters += 1; m -= 1 }
            if !exponentBetween, letters == 1, m < 0 || " (−+=/*×\n".contains(char(m)) { continue }
            let unit = word.split(separator: "/").last.map(String.init) ?? word
            if !exponentBetween {
                if units.contains(unit) && (numbers == [2] || numbers == [3]) { continue }
                if word == "10" || (word.count == 1 && word.first!.isLetter) { continue }
            }
            if lead.hasSuffix("Fig. ") || lead.hasSuffix("Fig.") || lead.hasSuffix("Table") || lead.hasSuffix("Scheme") { continue }
            if orbital.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil { continue }
            // A mark between two names is an affiliation ("Tanaka,1 Katsuyuki", "Hu1, Xiuyao Lang1"): on
            // the first page after any name, elsewhere (the author lists of a roadmap) only before a comma.
            if personName.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil, index == 0 || !word.hasSuffix(".") {
                var n = j
                while n < end, " \n,&*".contains(char(n)) { n += 1 }
                let following = text.substring(with: NSRange(location: n, length: min(14, end - n)))
                let comma = j < end && text.substring(with: NSRange(location: j, length: min(2, end - j))).contains(",")
                if following.range(of: #"^(?:[A-Z][\p{Ll}'’\-]+|and )"#, options: .regularExpression) != nil, index == 0 || comma { continue }
            }
            found.append((range, numbers))
        }

        // Written out.
        for m in written.matches(in: text as String, range: NSRange(location: 0, length: end)) {
            let inner = text.substring(with: m.range).replacingOccurrences(of: #"^[Rr]efs?\.?\s*"#, with: "", options: .regularExpression)
            guard let numbers = numbers(in: inner.replacingOccurrences(of: "and", with: ",")) else { continue }
            found.append((m.range, numbers))
        }

        // One marker where they overlap ("ref. [12]" is both written out and in brackets).
        found.sort { $0.range.location < $1.range.location }
        var merged: [(range: NSRange, numbers: [Int])] = []
        for item in found {
            if let last = merged.last, item.range.location < last.range.location + last.range.length {
                let end = max(last.range.location + last.range.length, item.range.location + item.range.length)
                merged[merged.count - 1] = (NSRange(location: last.range.location, length: end - last.range.location),
                                            Array(Set(last.numbers + item.numbers)).sorted())
            } else {
                merged.append(item)
            }
        }

        return merged.compactMap { item -> CitationMarker? in
            guard item.numbers.allSatisfy({ $0 >= 1 && $0 <= entryCount }),
                  let rect = page.selection(for: item.range)?.bounds(for: page), rect.width > 0 else { return nil }
            // Each number written out gets its own place.
            var parts: [(Int, CGRect)] = []
            var k = item.range.location
            let stop = item.range.location + item.range.length
            while k < stop {
                guard isDigit(k) else { k += 1; continue }
                var e = k
                while e < stop, isDigit(e) { e += 1 }
                if let n = Int(text.substring(with: NSRange(location: k, length: e - k))), item.numbers.contains(n),
                   let r = page.selection(for: NSRange(location: k, length: e - k))?.bounds(for: page), r.width > 0 {
                    parts.append((n, r))
                }
                k = e
            }
            return CitationMarker(page: index, rect: rect, numbers: item.numbers, parts: parts, range: item.range)
        }
    }

    /// The type size of running text on these pages: the most common size of their letters.
    public static func bodySize(of pages: [PDFPage]) -> CGFloat? {
        var sizes: [Int: Int] = [:]
        for page in pages {
            guard let attributed = page.attributedString else { continue }
            let text = attributed.string as NSString
            for i in stride(from: 0, to: text.length, by: 3) {
                guard let u = UnicodeScalar(text.character(at: i)), CharacterSet.letters.contains(u),
                      let font = attributed.attribute(.font, at: i, effectiveRange: nil) as? NSFont else { continue }
                sizes[Int((font.pointSize * 10).rounded()), default: 0] += 1
            }
        }
        return sizes.max(by: { $0.value < $1.value }).map { CGFloat($0.key) / 10 }
    }

    /// The entry numbers a citation's text names: "3", "3,5", "14–25", "21b,c,29". Nil when it names
    /// none, or holds something a citation does not (a leading zero, a backward range, a huge range).
    static func numbers(in text: String) -> [Int]? {
        let cleaned = text.replacingOccurrences(of: "\n", with: "")
        var result: [Int] = []
        for part in cleaned.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            let runs = piece.split(whereSeparator: { !$0.isNumber }).map(String.init)
            guard !runs.isEmpty else { continue }
            if runs.contains(where: { $0.hasPrefix("0") || $0.count > 3 }) { return nil }
            // A sign in front ("[−110]", a direction in a crystal) is not a citation.
            if let first = piece.first, "−–-—".contains(first) { return nil }
            let values = runs.compactMap(Int.init)
            if values.count == 2, piece.contains(where: { $0 == "–" || $0 == "-" || $0 == "—" || $0 == "−" }) {
                guard values[0] < values[1], values[1] - values[0] <= 60 else { return nil }
                result += Array(values[0]...values[1])
            } else if values.count == 1 {
                result.append(values[0])
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : Array(Set(result)).sorted()
    }
}
