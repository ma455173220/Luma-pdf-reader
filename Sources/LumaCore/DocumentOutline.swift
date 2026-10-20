import CoreGraphics
import Foundation
import PDFKit

/// One line of a document's outline.
public struct OutlineEntry: Equatable {
    public let title: String
    /// 0 for a top-level entry, 1 for one inside it, and so on.
    public let depth: Int
    /// The page it leads to, or nil when it leads nowhere inside the document.
    public let page: Int?
    /// The spot on that page, in page coordinates; nil when only the page is named.
    public let point: CGPoint?
    public let hasChildren: Bool

    public init(title: String, depth: Int, page: Int?, point: CGPoint?, hasChildren: Bool) {
        self.title = title
        self.depth = depth
        self.page = page
        self.point = point
        self.hasChildren = hasChildren
    }
}

public enum DocumentOutline {
    /// The outline a document carries, flattened in reading order: every entry is followed at once
    /// by the entries inside it. Empty when the document has no outline.
    ///
    /// The limits stop a damaged or hostile outline — one that loops back on itself, or runs to
    /// millions of entries — from hanging the app.
    public static func entries(of document: PDFDocument, limit: Int = 5000, maximumDepth: Int = 32) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [OutlineEntry] = []
        func visit(_ node: PDFOutline, depth: Int) {
            guard depth < maximumDepth else { return }
            for index in 0..<node.numberOfChildren {
                guard entries.count < limit, let child = node.child(at: index) else { return }
                var page: Int?
                var point: CGPoint?
                if let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination, let target = destination.page {
                    let found = document.index(for: target)
                    if found != NSNotFound, found >= 0, found < document.pageCount {
                        page = found
                        let raw = destination.point
                        if raw.y != kPDFDestinationUnspecifiedValue {
                            point = CGPoint(x: raw.x != kPDFDestinationUnspecifiedValue ? raw.x : target.bounds(for: .cropBox).minX, y: raw.y)
                        }
                    }
                }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(OutlineEntry(title: title.isEmpty ? "—" : title, depth: depth, page: page, point: point,
                                            hasChildren: child.numberOfChildren > 0))
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return entries
    }

    /// Which entries are on show, given the ones the reader has folded shut. Entries are named by
    /// their position in `entries`.
    public static func visibleRows(_ entries: [OutlineEntry], collapsed: Set<Int>) -> [Int] {
        var rows: [Int] = []
        // While inside a folded entry, everything deeper than it is hidden.
        var hiddenBelowDepth: Int?
        for (index, entry) in entries.enumerated() {
            if let limit = hiddenBelowDepth {
                if entry.depth > limit { continue }
                hiddenBelowDepth = nil
            }
            rows.append(index)
            if collapsed.contains(index) && entry.hasChildren { hiddenBelowDepth = entry.depth }
        }
        return rows
    }

    /// How an outline starts out: the top two levels open, anything deeper folded.
    public static func initiallyCollapsed(_ entries: [OutlineEntry]) -> Set<Int> {
        Set(entries.indices.filter { entries[$0].depth >= 1 && entries[$0].hasChildren })
    }

    /// The last entry that starts at or before a place in the document: the section that place is in.
    public static func entry(containingPage page: Int, in entries: [OutlineEntry]) -> Int? {
        entry(containing: page, at: nil, in: entries)
    }

    /// The section being read when the line read is at height `y` (page coordinates) on `page`: of the
    /// entries on that page at or above the line, the nearest above it — on a page in two columns a
    /// heading high in the right column comes after one just above the line in the left; failing that,
    /// the last entry on an earlier page. An entry that names only its page starts at the page's top.
    /// Without a height, every entry on the page counts and the last is taken.
    public static func entry(containing page: Int, at y: CGFloat?, in entries: [OutlineEntry]) -> Int? {
        let earlier = entries.indices.last { (entries[$0].page ?? Int.max) < page }
        let onPage = entries.indices.filter { entries[$0].page == page }
        guard let y else { return onPage.last ?? earlier }
        func distance(_ index: Int) -> CGFloat? {
            guard let point = entries[index].point else { return .greatestFiniteMagnitude }
            return point.y >= y ? point.y - y : nil
        }
        let above = onPage.compactMap { index in distance(index).map { (index, $0) } }
        // The nearest; among equally near, the later.
        return above.min { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 > $1.0) }?.0 ?? earlier
    }
}

extension DocumentOutline {
    /// An outline written out, to pass from the process that worked it out to the reader.
    public static func encoded(_ entries: [OutlineEntry]) -> Data {
        let rows: [[String: Any]] = entries.map { entry in
            var row: [String: Any] = ["title": entry.title, "depth": entry.depth, "children": entry.hasChildren]
            if let page = entry.page { row["page"] = page }
            if let point = entry.point { row["x"] = Double(point.x); row["y"] = Double(point.y) }
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
    }

    /// An outline read back, checked against the document it is for: entries leading to pages it
    /// does not have lead nowhere. Nil when the data is not an outline.
    public static func decoded(_ data: Data, pageCount: Int, limit: Int = 5000) -> [OutlineEntry]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.prefix(limit).compactMap { row in
            guard let title = row["title"] as? String, let depth = row["depth"] as? Int, depth >= 0, depth < 32 else { return nil }
            let page = (row["page"] as? Int).flatMap { $0 >= 0 && $0 < pageCount ? $0 : nil }
            let point = page != nil ? (row["x"] as? Double).flatMap { x in (row["y"] as? Double).map { CGPoint(x: x, y: $0) } } : nil
            return OutlineEntry(title: title, depth: depth, page: page, point: point, hasChildren: row["children"] as? Bool ?? false)
        }
    }
}
