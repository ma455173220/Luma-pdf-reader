import CoreGraphics
import Foundation
import PDFKit

/// Where a preview should open: the place a link names, put right by what the link says.
///
/// A document's own links do not always name the place they lead to well: some name only a height,
/// not which column (a two-column page then gets the wrong column), and some name a height well above
/// the target (a reference-list entry three lines further down, a table's caption half a column
/// lower). So the target is looked for on the page by what the link is written as: a citation's
/// number at the start of its entry, a figure's or table's caption by its label (ADR 0006). Only the
/// pages concerned are read, from the reading document.
public enum PreviewTarget {
    public struct Found: Equatable {
        public let page: Int
        public let point: CGPoint
        /// Whether the preview may show only the column the target is in: a reference-list entry, or a
        /// figure or table whose caption is set within one column.
        public let inColumn: Bool
        /// For a reference-list entry: its lines, for the buttons that copy it or look it up.
        public let entry: [PreviewText.Line]
    }

    /// What a link written as `text` (with a little of what comes before it on its line, as
    /// "Figure 1(a)" when only "1(a)" is the link) leads to, on or near `page`, from the height the link
    /// names (`point`, nil for none). Nil when nothing better than the named place is found.
    /// `from`: the page the link is on. A number leading to the same page or an earlier one is not
    /// taken for a citation (an affiliation, a footnote, an equation).
    public static func find(text: String, page: Int, point: CGPoint?, in document: PDFDocument, bodySize: CGFloat?,
                            from: Int? = nil) -> Found? {
        // A figure or table: its caption, by its label, on the page named or one either side.
        if let label = FigureReferences.labels(in: NSAttributedString(string: text)).last,
           let number = label.numbers.compactMap(\.number).first {
            // Without the running text's size a line of the body starting "Table 1." could pass for a
            // caption: the named place is kept until it is known.
            guard let bodySize, bodySize > 0 else { return nil }
            for index in [page, page + 1, page - 1] where index >= 0 && index < document.pageCount {
                guard let shown = document.page(at: index) else { continue }
                let captions = FigureReferences.captions(on: shown, index: index, bodySize: bodySize)
                    .filter { $0.kind == label.kind && $0.number == number && !$0.continued }
                // Nearest the named place when there are several (a caption repeated, or in two languages).
                let best = captions.min { a, b in
                    distance(a, on: shown, to: index == page ? point : nil) < distance(b, on: shown, to: index == page ? point : nil)
                }
                if let best, let start = FigureReferences.target(of: best, in: document) {
                    // A caption set within one column of a two-column page: its figure or table is in
                    // that column too, and is shown as wide as the preview. Otherwise the whole width.
                    let box = shown.bounds(for: .cropBox)
                    // The caption's first line, not just its label: a caption across the page belongs to
                    // a figure across the page.
                    let label = shown.selection(for: best.range)?.bounds(for: shown) ?? .zero
                    let caption = PreviewText.lines(of: shown).first { $0.rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: label.midX, y: label.midY)) }?.rect ?? label
                    let oneColumn = caption.width > 0 && (caption.maxX < box.midX + 10 || caption.minX > box.midX - 10)
                    return Found(page: start.page, point: CGPoint(x: oneColumn ? caption.minX : start.point.x, y: start.point.y),
                                 inColumn: oneColumn && start.page == index, entry: [])
                }
            }
            return nil
        }
        // A citation: the entry starting with its number, the one nearest the named height, and not
        // far from it when a height is named.
        guard let number = firstNumber(text), from.map({ page > $0 }) ?? true, let shown = document.page(at: page) else { return nil }
        let lines = PreviewText.lines(of: shown)
        let starting = lines.filter { starts($0.text, with: number) }
        let y = point?.y ?? shown.bounds(for: .cropBox).maxY
        guard let line = starting.min(by: { abs($0.rect.maxY - y) < abs($1.rect.maxY - y) }), point == nil || abs(line.rect.maxY - y) <= 150,
              let index = lines.firstIndex(of: line) else { return nil }
        let at = CGPoint(x: line.rect.minX, y: line.rect.maxY + 1)
        var (entry, runsOn) = PreviewText.entryRunning(in: lines, startingAt: index)
        // Run to the foot of the page: on at the head of the next page, if no entry starts there.
        if runsOn, let next = document.page(at: page + 1) {
            let box = next.bounds(for: .cropBox)
            entry += PreviewText.continuation(in: PreviewText.lines(of: next), pageHeight: box.height, top: box.maxY, of: entry).prefix(12 - entry.count)
        }
        return Found(page: page, point: at, inColumn: true, entry: entry)
    }

    private static func distance(_ caption: FigureCaption, on page: PDFPage, to point: CGPoint?) -> CGFloat {
        guard let point, let rect = page.selection(for: caption.range)?.bounds(for: page) else { return 0 }
        return abs(rect.maxY - point.y)
    }

    /// What a link on `page` is written as, with a little of what comes before it on its line, so that
    /// "Figure 1(a)" is read when only "1(a)" is the link; a citation's own text when it is a number.
    public static func linkText(_ rect: CGRect, on page: PDFPage) -> String {
        let own = (page.selection(for: rect.insetBy(dx: 1, dy: 1))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if firstNumber(own) != nil {
            // A number: a citation, unless a figure's or table's word stands right before it.
            let before = (page.selection(for: CGRect(x: rect.minX - 70, y: rect.minY + rect.height * 0.25, width: 70, height: rect.height * 0.5))?.string ?? "")
            if before.range(of: #"(?:Fig(?:ure)?s?\.?|FIG(?:URE)?S?\.?|Tables?|TABLES?|Schemes?|Tab\.)\s*$"#, options: .regularExpression) != nil { return before + own }
            return own
        }
        let wider = CGRect(x: rect.minX - 70, y: rect.minY + rect.height * 0.25, width: rect.width + 70, height: rect.height * 0.5)
        return (page.selection(for: wider)?.string ?? own).replacingOccurrences(of: "\n", with: " ")
    }

    /// Whether a link's text is written as a citation (for the checks).
    public static func debugIsCitation(_ text: String) -> Bool { firstNumber(text) != nil }

    /// The first number a citation is written with: "67", "[67]", "1,2", "3–5", "(12)"; at most three
    /// digits.
    static func firstNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Up to three digits: a year linked in an author-year citation ("Smith et al. (2019)") is no number.
        guard trimmed.range(of: #"^[\[\(]?\d{1,3}(?:\s*[,–\-−]\s*\d{1,3})*[\]\)]?$"#, options: .regularExpression) != nil,
              let digits = trimmed.range(of: #"\d{1,3}"#, options: .regularExpression) else { return nil }
        return Int(trimmed[digits])
    }

    /// Whether a line starts the numbered entry `number`: "[67] …", "67. …", "(67) …", "67 …" or a
    /// number set on its own ("67.").
    static func starts(_ line: String, with number: Int) -> Bool {
        line.range(of: #"^\s*(?:\[\#(number)\]|\(\#(number)\)|\#(number)\.(?!\d)|\#(number)(?=\s+\S)|\#(number)\s*$)"#, options: .regularExpression) != nil
    }
}
