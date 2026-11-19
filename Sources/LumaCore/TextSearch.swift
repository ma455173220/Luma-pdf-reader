import Foundation

/// Finds a query in a page's text the way a reader reads it: a line break counts as a space, and a
/// word broken across two lines with a hyphen counts as one word.
///
/// The system's own search matches the text character for character, so a phrase running onto the
/// next line, or a word hyphenated at the end of a line, is never found there.
public enum TextSearch {
    /// Where `query` occurs in `text`, as ranges of `text`'s UTF-16 units, in order and not
    /// overlapping. Letter case is ignored unless `options.matchCase`; accents always are.
    public static func ranges(of query: String, in text: String, options: SearchOptions = SearchOptions()) -> [NSRange] {
        let wanted = Folded(query, ignoringCase: !options.matchCase).keys
        guard let first = wanted.first, first != Folded.space else { return [] }
        let units = Array(text.utf16)
        let folded = Folded(units, ignoringCase: !options.matchCase)
        let keys = folded.keys
        var found: [NSRange] = []
        var start = 0
        while start < keys.count {
            guard keys[start] == first, let end = matchEnd(wanted, in: keys, from: start) else {
                start += 1
                continue
            }
            let range = NSRange(location: folded.starts[start], length: folded.ends[end - 1] - folded.starts[start])
            if !options.wholeWords || isWholeWord(range, in: units, text: text) {
                found.append(range)
                start = end
            } else {
                start += 1
            }
        }
        return found
    }

    /// One past the last key of a match of `wanted` beginning at `start`, or nil.
    private static func matchEnd(_ wanted: [UInt16], in keys: [UInt16], from start: Int) -> Int? {
        var at = start, next = 0
        while next < wanted.count {
            guard at < keys.count else { return nil }
            let key = keys[at]
            if key == Folded.lineBreakHyphen {
                // "GB-containing" reads the hyphen as written; "evolution" reads the word whole.
                if wanted[next] == Folded.hyphen { next += 1 }
                at += 1
            } else if key == Folded.lineBreak {
                // After a hyphen: "10-20" or "10- 20" both read it.
                if wanted[next] == Folded.space { next += 1 }
                at += 1
            } else if key == wanted[next] {
                at += 1
                next += 1
            } else {
                return nil
            }
        }
        return at
    }

    private static func isWholeWord(_ range: NSRange, in units: [UInt16], text: String) -> Bool {
        let whole = text as NSString
        func character(at index: Int) -> Character? {
            guard index >= 0, index < units.count else { return nil }
            return whole.substring(with: whole.rangeOfComposedCharacterSequence(at: index)).first
        }
        return SearchOptions.isWholeWord(whole.substring(with: range), before: character(at: range.location - 1),
                                         after: character(at: NSMaxRange(range)))
    }
}

/// Text reduced to what a search compares: letters folded, each run of white space one space, and a
/// hyphen at a line break between two letters one marker. Each key remembers which UTF-16 units of
/// the original it stands for.
struct Folded {
    static let space: UInt16 = 0x20
    static let hyphen: UInt16 = 0x2D
    /// A noncharacter, so it never comes from the text itself.
    static let lineBreakHyphen: UInt16 = 0xFFFF
    /// A line break straight after a hyphen, which may or may not stand for a space.
    static let lineBreak: UInt16 = 0xFFFE

    private(set) var keys: [UInt16] = []
    private(set) var starts: [Int] = []
    private(set) var ends: [Int] = []

    init(_ string: String, ignoringCase: Bool) {
        let units = Array(string.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
        self.init(units, ignoringCase: ignoringCase)
    }

    init(_ units: [UInt16], ignoringCase: Bool) {
        keys.reserveCapacity(units.count)
        starts.reserveCapacity(units.count)
        ends.reserveCapacity(units.count)
        var cache: [UInt16: [UInt16]] = [:]
        var i = 0
        while i < units.count {
            let unit = units[i]
            if Folded.isSpace(unit) {
                let from = i
                while i < units.count && Folded.isSpace(units[i]) { i += 1 }
                if keys.last == Folded.space {
                    ends[ends.count - 1] = i
                } else if keys.last == Folded.hyphen, units[from..<i].contains(where: Folded.isLineBreak) {
                    add(Folded.lineBreak, from, i)
                } else {
                    add(Folded.space, from, i)
                }
                continue
            }
            if unit == 0x00AD {
                // A soft hyphen: where a word may break, shown only when it does.
                add(Folded.lineBreakHyphen, i, i + 1)
                i += 1
                continue
            }
            if Folded.isHyphen(unit), let last = keys.last, Folded.isLetter(last) {
                var after = i + 1, brokenLine = false
                while after < units.count && Folded.isSpace(units[after]) {
                    if Folded.isLineBreak(units[after]) { brokenLine = true }
                    after += 1
                }
                if brokenLine, after < units.count, Folded.isLetterUnit(units[after]) {
                    add(Folded.lineBreakHyphen, i, after)
                    i = after
                    continue
                }
            }
            if (0x0300...0x036F).contains(unit), !starts.isEmpty {
                // A combining accent: part of the letter before it, and accents are not compared.
                ends[ends.count - 1] = i + 1
                i += 1
                continue
            }
            if unit < 0x80 {
                add(ignoringCase && (0x41...0x5A).contains(unit) ? unit + 0x20 : unit, i, i + 1)
            } else if Folded.isHyphen(unit) {
                add(Folded.hyphen, i, i + 1)
            } else if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
                add(unit, i, i + 1)
            } else {
                let folded: [UInt16]
                if let known = cache[unit] {
                    folded = known
                } else {
                    let options: String.CompareOptions = ignoringCase ? [.caseInsensitive, .diacriticInsensitive] : [.diacriticInsensitive]
                    folded = Array(String(utf16CodeUnits: [unit], count: 1).folding(options: options, locale: nil).utf16)
                    cache[unit] = folded
                }
                for key in folded { add(key, i, i + 1) }
            }
            i += 1
        }
    }

    private mutating func add(_ key: UInt16, _ start: Int, _ end: Int) {
        keys.append(key)
        starts.append(start)
        ends.append(end)
    }

    static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    static func isLineBreak(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    static func isHyphen(_ unit: UInt16) -> Bool { unit == 0x2D || unit == 0x2010 || unit == 0x2011 }

    /// A folded key that is a letter (only what a hyphenated word can end with matters here).
    static func isLetter(_ key: UInt16) -> Bool {
        key < lineBreak && isLetterUnit(key)
    }

    static func isLetterUnit(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic
    }
}
