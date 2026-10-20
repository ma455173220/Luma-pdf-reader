import CoreGraphics
import Foundation
import PDFKit

/// A numbered entry of a document's reference list.
public struct ReferenceEntry: Equatable {
    public let number: Int
    public let page: Int
    /// The entry's label ("[12]", "12.", "(12)" or "12"), in the page's own coordinates.
    public let labelRect: CGRect

    /// Where a preview of the entry looks: the top-left corner of its label.
    public var point: CGPoint { CGPoint(x: labelRect.minX, y: labelRect.maxY) }
}

/// The numbered reference list at the end of a paper, found from the text alone.
///
/// The list starts at a heading ("References", "Notes and references", "参考文献"…) or, when there is
/// none, at a line that begins with label 1 and is soon followed by label 2. From there the entries
/// are the lines that begin with the next label in sequence, all written the same way. A number out
/// of sequence (a page number, a table row) is not an entry.
public struct ReferenceList {
    public enum Style { case brackets, parentheses, dotted, plain }

    public let entries: [Int: ReferenceEntry]
    public let style: Style
    /// Where the list starts: citations are looked for only before it.
    public let startPage: Int
    public let startOffset: Int

    public var count: Int { entries.count }

    private static let heading = try! NSRegularExpression(
        pattern: #"^\s*(?:[■•▪●◆]\s*)?(?:\d+\.?\s*)?(?:r\s?e\s?f\s?e\s?r\s?e\s?n\s?c\s?e\s?s(?:\s+and\s+notes)?|notes\s+and\s+references|bibliography|literature\s+cited|参考文献)\s*[:：]?\s*$"#,
        options: [.caseInsensitive])

    /// A label at the place searched from, followed by text or by the next label ("25. 26. 27. Bianchi…").
    /// A label in brackets or parentheses may also run straight into the name ("(13)Li,K.").
    private static let label = try! NSRegularExpression(pattern: #"\G\s*(?:\[(\d{1,3})\]|\((\d{1,3})\)|(\d{1,3})(\.?))(?:(?=\s+(?:[^\d\s]|\d{1,3}\.(?:\s|$)))|(?<=[\])])(?=[A-Z]))"#)

    /// What follows a label that sits in the middle of a line: the start of an author's name.
    private static let author = try! NSRegularExpression(pattern: #"^\s+(?:[a-z]\)\s+)?(?:[A-Z][\p{L}'’\-]+,?\s+[A-Z]\.|(?:[A-Z]\.\s?){1,3}\s?[A-Z][\p{L}'’\-]+)"#)

    /// Finds the list, reading pages from the end of the document. Nil when there is no numbered list.
    public static func find(in document: PDFDocument) -> ReferenceList? {
        guard document.pageCount > 0 else { return nil }
        let lowest = document.pageCount / 3
        var start: (page: Int, offset: Int)?
        headingSearch: for p in stride(from: document.pageCount - 1, through: lowest, by: -1) {
            for line in lines(of: document.page(at: p)) where heading.firstMatch(in: line.text, range: NSRange(location: 0, length: (line.text as NSString).length)) != nil {
                start = (p, line.offset)
                break headingSearch
            }
        }
        if let start, let list = entries(in: document, from: start), list.count >= 3 { return list }
        // No heading: the first line in the later part of the document that starts the numbering with
        // an author's name ("1 M. Fujimoto and…"), not a numbered point of the text.
        for p in (document.pageCount * 2 / 5)..<document.pageCount {
            for line in lines(of: document.page(at: p)) {
                guard let first = labels(in: line.text).first, first.number == 1 else { continue }
                let rest = (line.text as NSString).substring(from: first.range.location + first.range.length + (first.style == .brackets || first.style == .parentheses || first.style == .dotted ? 1 : 0))
                guard author.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil else { continue }
                if let list = entries(in: document, from: (p, line.offset)), list.count >= 3 { return list }
            }
        }
        return nil
    }

    private struct Line { let text: String; let offset: Int }

    private static func lines(of page: PDFPage?) -> [Line] {
        guard let string = page?.string else { return [] }
        var result: [Line] = []
        var offset = 0
        for text in string.components(separatedBy: "\n") {
            result.append(Line(text: text, offset: offset))
            offset += (text as NSString).length + 1
        }
        return result
    }

    /// The labels a line begins with: one, or several when the labels came out as their own column
    /// ("[1] [2] [3] Dresselhaus…").
    private static func labels(in text: String) -> [(number: Int, style: Style, range: NSRange)] {
        let ns = text as NSString
        var found: [(Int, Style, NSRange)] = []
        var from = 0
        while from < ns.length, let m = label.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) {
            let groups: [(Int, Style)] = [(1, .brackets), (2, .parentheses), (3, .plain)]
            guard let (index, kind) = groups.first(where: { m.range(at: $0.0).location != NSNotFound }),
                  let number = Int(ns.substring(with: m.range(at: index))) else { break }
            let style: Style = kind == .plain && m.range(at: 4).length > 0 ? .dotted : kind
            found.append((number, style, m.range(at: index)))
            from = m.range.location + m.range.length
        }
        return found
    }

    /// The entries from a starting place: each line that begins with the next label in sequence, in
    /// the style of the first. A label may also sit in the middle of a line, where a running head was
    /// joined to it, if an author's name follows.
    private static func entries(in document: PDFDocument, from start: (page: Int, offset: Int)) -> ReferenceList? {
        // Labels that came out in a row ("24. 25. 26. 27. 28. Sha, S. …") form the list's own column;
        // the text can put them anywhere, even before the heading. They fill in what the walk below
        // does not find in order.
        var column: [Int: [(style: Style, entry: ReferenceEntry)]] = [:]
        for p in start.page..<min(document.pageCount, start.page + 30) {
            guard let page = document.page(at: p) else { continue }
            for line in lines(of: page) {
                let found = labels(in: line.text)
                guard found.count >= 2 else { continue }
                for label in found {
                    let rect = page.selection(for: NSRange(location: line.offset + label.range.location, length: label.range.length))?.bounds(for: page) ?? .zero
                    column[label.number, default: []].append((label.style, ReferenceEntry(number: label.number, page: p, labelRect: rect)))
                }
            }
        }
        var entries: [Int: ReferenceEntry] = [:]
        var style: Style?
        var expected = 1
        func fromColumn(_ n: Int) -> ReferenceEntry? { column[n]?.first(where: { $0.style == style })?.entry }
        for p in start.page..<document.pageCount {
            guard let page = document.page(at: p) else { continue }
            for line in lines(of: page) where p > start.page || line.offset >= start.offset {
                var candidates = labels(in: line.text)
                if let style, !candidates.contains(where: { $0.number == expected }), let inside = labelInside(line.text, number: expected, style: style) {
                    candidates.append(inside)
                }
                for label in candidates {
                    if let style, label.style != style { continue }
                    // The next label, or one further when a single label is damaged, or further still
                    // when the labels between are in the column.
                    let reachable = label.number == expected || (style != nil && label.number == expected + 1)
                        || (style != nil && label.number > expected && (expected..<label.number).filter { entries[$0] == nil && fromColumn($0) == nil }.count <= 1)
                    guard reachable else { continue }
                    style = style ?? label.style
                    for n in expected..<label.number where entries[n] == nil { entries[n] = fromColumn(n) }
                    let rect = page.selection(for: NSRange(location: line.offset + label.range.location, length: label.range.length))?.bounds(for: page) ?? .zero
                    entries[label.number] = ReferenceEntry(number: label.number, page: p, labelRect: rect)
                    expected = label.number + 1
                }
            }
        }
        guard let style, entries[1] != nil else { return nil }
        // Labels after the last one found in order, from the column, passing over one missing label.
        while let next = fromColumn(expected) ?? fromColumn(expected + 1) {
            entries[next.number] = next
            expected = next.number + 1
        }
        return ReferenceList(entries: entries, style: style, startPage: start.page, startOffset: start.offset)
    }

    /// A label for the expected entry in the middle of a line, followed by an author's name.
    private static func labelInside(_ text: String, number: Int, style: Style) -> (number: Int, style: Style, range: NSRange)? {
        let written: String
        switch style {
        case .brackets: written = "[\(number)]"
        case .parentheses: written = "(\(number))"
        case .dotted: written = "\(number)."
        case .plain: written = "\(number)"
        }
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: written, range: search)
            guard r.location != NSNotFound else { return nil }
            search = NSRange(location: r.location + r.length, length: ns.length - r.location - r.length)
            let before = r.location == 0 ? " " : ns.substring(with: NSRange(location: r.location - 1, length: 1))
            guard before.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let rest = ns.substring(from: r.location + r.length)
            if author.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil {
                let digits = style == .brackets || style == .parentheses ? NSRange(location: r.location + 1, length: r.length - 2)
                    : NSRange(location: r.location, length: String(number).count)
                return (number, style, digits)
            }
        }
    }
}
