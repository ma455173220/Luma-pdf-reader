import CoreGraphics
import Foundation
import PDFKit

/// The reference-list entry a link's target falls on, as lines of its page, so that the entry can be
/// copied or looked up (ADR 0006). Only that one page is read.
public enum PreviewText {
    public struct Line: Equatable {
        public let text: String
        /// In the page's own coordinates.
        public let rect: CGRect

        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    /// The page's lines of text, in reading order.
    public static func lines(of page: PDFPage) -> [Line] {
        let box = page.bounds(for: .cropBox)
        return (page.selection(for: box)?.selectionsByLine() ?? []).compactMap { line in
            guard let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rect = line.bounds(for: page)
            return rect.isEmpty ? nil : Line(text: text, rect: rect)
        }
    }

    /// The start of a numbered reference-list entry: "[12]", "(12)" before a word (not a year in
    /// brackets ending the entry before, "(2009)."), "12." or "12 " before a capital.
    private static let entryStart = try! NSRegularExpression(pattern: #"^\s*(?:\[\d{1,4}\]|\(\d{1,4}\)(?=\s*\p{L})|\d{1,4}\.(?!\d)|\d{1,4}\s+\p{Lu})"#)

    /// The entry the place `point` (page coordinates; a link's target, which names the top of where
    /// it leads) falls on: of the lines whose top is near the point's height, in its column when it
    /// names one (`knownX`), one that starts a numbered entry first, then the one nearest the point;
    /// and the lines after it up to the next entry, a gap, a change of column, or (in a list set with
    /// a hanging indent) the next line back at the margin. At most eight lines. Empty when there is
    /// no text there.
    public static func entry(in lines: [Line], at point: CGPoint, knownX: Bool = true) -> [Line] {
        let near = lines.filter { line in
            line.rect.maxY >= point.y - 40 && line.rect.minY <= point.y + 4
                && (!knownX || (line.rect.minX <= point.x + 40 && line.rect.maxX >= point.x))
        }
        let numbered = near.filter(startsEntry)
        func closeness(_ line: Line) -> CGFloat { abs(min(line.rect.maxY, point.y) - point.y) + abs(line.rect.maxY - point.y) * 0.1 }
        guard let first = (numbered.isEmpty ? near : numbered).min(by: { closeness($0) < closeness($1) }),
              let start = lines.firstIndex(of: first) else { return [] }
        return entry(in: lines, startingAt: start)
    }

    /// The entry that starts with line `start`: it and the lines after it up to the next entry, a gap,
    /// or (in a list set with a hanging indent) the next line back at the margin; at the foot of a
    /// column, on at the head of the next column (ADR 0006).
    public static func entry(in lines: [Line], startingAt index: Int) -> [Line] {
        entryRunning(in: lines, startingAt: index).lines
    }

    /// The same, and whether the entry may go on onto the next page: it ran to the foot of the page's
    /// last column it was in and does not read as finished.
    public static func entryRunning(in lines: [Line], startingAt index: Int) -> (lines: [Line], runsOn: Bool) {
        var (found, end) = column(in: lines, startingAt: index)
        var used = Set(found.compactMap { lines.firstIndex(of: $0) })
        // A list set with a hanging indent goes on, in the next column, indented as well.
        let hanging = found.count >= 2 && !isBareNumber(found[0].text) && found[1].rect.minX - found[0].rect.minX > 3
        // At the foot of a column, unfinished: on at the head of the column to its right, unless an
        // entry starts there.
        while end == .foot, found.count < 12, let last = found.last, !looksFinished(last.text) {
            // A line the page lists as one across both columns: where the entry goes on is not known.
            if spansColumns(last, in: lines) { return (found, false) }
            // Set in the entry's size: not a running head in larger type above the column.
            let right = lines.indices.filter { !used.contains($0) && lines[$0].rect.minX >= last.rect.maxX - 10 && sameSize(lines[$0], as: found) }
            // The page's last column: the entry may go on overleaf.
            if right.isEmpty { return (found, true) }
            guard let left = right.map({ lines[$0].rect.minX }).min(),
                  let head = right.filter({ abs(lines[$0].rect.minX - left) < 30 }).max(by: { lines[$0].rect.maxY < lines[$1].rect.maxY }),
                  // The head of that column is level with the entry's start or above it (not text further down).
                  lines[head].rect.maxY >= found[0].rect.minY,
                  !hanging || lines[head].rect.minX - left > 3 || right.filter({ abs(lines[$0].rect.minX - left) <= 3 }).count == right.count,
                  let more = goesOn(lines, at: head, like: found)
            else { return (found, false) }
            found += more.lines.prefix(12 - found.count)
            more.lines.forEach { line in lines.firstIndex(of: line).map { used.insert($0) } }
            end = more.end
        }
        return (found, end == .foot && found.count < 12 && found.last.map { !looksFinished($0.text) && !spansColumns($0, in: lines) } == true)
    }

    /// The lines of an entry continued from the page before (`before`, its lines so far): the head of
    /// the page's first column, below its running head, unless an entry starts there.
    public static func continuation(in lines: [Line], pageHeight: CGFloat, top: CGFloat, of before: [Line]) -> [Line] {
        let below = lines.filter { $0.rect.maxY < top - pageHeight * 0.07 }
        guard let left = below.map(\.rect.minX).min(),
              let head = below.filter({ abs($0.rect.minX - left) < 30 }).max(by: { $0.rect.maxY < $1.rect.maxY }),
              // Near the top: not a column that starts lower down, after a figure or the paper's end.
              head.rect.maxY > top - pageHeight * 0.3,
              let index = lines.firstIndex(of: head), let more = goesOn(lines, at: index, like: before) else { return [] }
        return more.lines
    }

    /// The lines from `head` down its column, if they read as the rest of the entry `before`: set in the
    /// same size, not a heading, footer or page number, and followed by the next entry (so that the
    /// column is a reference list, not body text or the end of the paper).
    private static func goesOn(_ lines: [Line], at head: Int, like before: [Line]) -> (lines: [Line], end: ColumnEnd)? {
        let line = lines[head]
        guard sameSize(line, as: before), line.rect.width > line.rect.height * 3,
              !startsEntry(line), !isBareNumber(line.text), !isPageFurniture(line.text) else { return nil }
        let more = column(in: lines, startingAt: head)
        guard more.end == .nextEntry, !more.lines.contains(where: { isPageFurniture($0.text) || spansColumns($0, in: lines) }) else { return nil }
        return more
    }

    /// Whether `line` is set in the size of the lines `others` (the middle of their heights).
    private static func sameSize(_ line: Line, as others: [Line]) -> Bool {
        let heights = others.map(\.rect.height).sorted()
        guard !heights.isEmpty else { return false }
        let size = heights[heights.count / 2]
        return abs(line.rect.height - size) <= max(1.5, size * 0.2)
    }

    /// Why an entry's lines down one column stopped.
    enum ColumnEnd { case foot, nextEntry, gap, full }

    /// An entry's lines down one column, and why they stopped: at its foot (no line below), at the
    /// next entry, at a gap, or at the most an entry is given.
    private static func column(in lines: [Line], startingAt index: Int) -> (lines: [Line], end: ColumnEnd) {
        guard lines.indices.contains(index) else { return ([], .gap) }
        let first = lines[index]
        var start = index
        var found = [first]
        var previous = first
        // A number set on a line of its own beside its entry ("86." in a column of its own): the entry
        // goes on from the line beside it.
        if isBareNumber(first.text), let beside = lines.filter({ abs($0.rect.midY - first.rect.midY) < first.rect.height * 0.7 && $0.rect.minX >= first.rect.maxX - 2 })
            .min(by: { $0.rect.minX < $1.rect.minX }), let at = lines.firstIndex(of: beside) {
            found.append(beside)
            previous = beside
            start = at
        }
        // The entry's own text: the line beside a number set apart, else its first line.
        let lead = found.last!
        let margin = lead.rect.minX
        let numbers = lines.filter { isBareNumber($0.text) }
        var used: Set<Int> = [index, start]
        var end = ColumnEnd.full
        // Line by line downwards, by where the lines are rather than the order the page lists them in
        // (on some pages the two columns' lines are listed in turn).
        while found.count < 12 {
            // A piece of the same line, set apart (an accented letter, a change of type).
            if let piece = lines.indices.first(where: { k in
                !used.contains(k) && abs(lines[k].rect.midY - previous.rect.midY) < 2
                    && lines[k].rect.minX >= previous.rect.maxX - 5 && lines[k].rect.minX < previous.rect.maxX + 40
                    // Not the next column's line beside a short one, across a narrow gutter.
                    && !startsEntry(lines[k]) && !isBareNumber(lines[k].text) && !spansGutter(previous, lines[k], in: lines)
            }) {
                used.insert(piece)
                found.append(lines[piece])
                previous = lines[piece]
                continue
            }
            guard let next = lines.indices.filter({ k in
                !used.contains(k) && lines[k].rect.maxY < previous.rect.midY
                    && lines[k].rect.maxX > lead.rect.minX && lines[k].rect.minX < lead.rect.maxX && abs(lines[k].rect.minX - margin) < 60
            }).max(by: { lines[$0].rect.maxY < lines[$1].rect.maxY }) else {
                end = .foot
                break
            }
            let line = lines[next]
            // Lines may overlap a little where they are set close.
            let gap = previous.rect.minY - line.rect.maxY
            // A number of its own beside the line: the next entry starts there.
            let numbered = numbers.contains { $0 != first && abs($0.rect.midY - line.rect.midY) < line.rect.height * 0.7
                && $0.rect.maxX <= line.rect.minX + 2 && $0.rect.maxX >= line.rect.minX - 30 }
            guard gap > -previous.rect.height * 0.6, gap < previous.rect.height * 0.9 + 2 else { end = .gap; break }
            guard !startsEntry(line), !isBareNumber(line.text), !numbered else { end = .nextEntry; break }
            // A hanging indent: the entry's later lines are set in from its first; one back at the
            // margin starts the next entry.
            if lead == first, found.count >= 2, abs(found[1].rect.minX - first.rect.minX) > 3, abs(line.rect.minX - first.rect.minX) <= 2 { end = .nextEntry; break }
            used.insert(next)
            found.append(line)
            previous = line
        }
        return (found, end)
    }

    /// A line that ends an entry: one ending in a number (a page, a year, a volume), or in a number
    /// and a closing bracket, or in a full stop after a word with a number in it (a DOI).
    private static func looksFinished(_ text: String) -> Bool {
        text.range(of: #"\d[\)\]]?\.?\s*$|\S*\d\S*\.\s*$"#, options: .regularExpression) != nil
    }

    /// Whether the page lists `line` as one line across two columns: far wider than the lines that
    /// start where it starts.
    private static func spansColumns(_ line: Line, in lines: [Line]) -> Bool {
        let widths = lines.filter { abs($0.rect.minX - line.rect.minX) < 30 }.map(\.rect.width).sorted()
        return widths.count >= 5 && line.rect.width > widths[widths.count / 2] * 1.35
    }

    /// Whether `piece`, beside `line`, starts where other lines start well apart from `line`'s own:
    /// it is in the next column, not part of the same line.
    private static func spansGutter(_ line: Line, _ piece: Line, in lines: [Line]) -> Bool {
        lines.filter { abs($0.rect.minX - piece.rect.minX) < 2 }.count >= 3 && piece.rect.minX - line.rect.minX > 100
    }

    /// What a page carries besides its text: a download or licence notice, a journal's footer, a page
    /// number, a chapter heading.
    private static func isPageFurniture(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:\d+\s*/\s*\d+|\d+|Chapter\b.*|View Article Online.*)\s*$|Downloaded\s+(?:from|by)\b|Published on\b|licensed under|https?://(?:dx\.)?doi\.org/\S+\s+\S"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isBareNumber(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:\[\d{1,4}\]|\(\d{1,4}\)|\d{1,4}\.?)\s*$"#, options: .regularExpression) != nil
    }

    private static func startsEntry(_ line: Line) -> Bool {
        entryStart.firstMatch(in: line.text, range: NSRange(location: 0, length: (line.text as NSString).length)) != nil
    }

    /// Whether an entry reads like a reference to another work: a year in it, and not a caption.
    public static func looksLikeReference(_ lines: [Line]) -> Bool {
        let text = lines.map(\.text).joined(separator: " ")
        guard text.range(of: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#, options: .regularExpression) != nil else { return false }
        return text.range(of: #"^\s*(?:Fig(?:ure)?\.?|Table|Scheme)\s*\d"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// An entry's text without its number in front, for searching: "[12] A. Smith, …" → "A. Smith, …".
    public static func withoutNumber(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*(?:\[\d{1,4}\]|\(\d{1,4}\)|\d{1,4}\.(?!\d)|\d{1,4}(?=\s+\p{Lu}))\s*"#, with: "", options: .regularExpression)
    }
}
