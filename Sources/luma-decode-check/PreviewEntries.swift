import Foundation
import LumaCore
import PDFKit

// --preview-entries: what a preview would mark for each document's own links to later pages (its
// citations, mostly) and for the citations decoding works out: the entry found at each target, one
// line per link, for reading through by eye. Counts how many found nothing, and how many found
// text that does not start an entry.
func checkPreviewEntries(paths: [String]) {
    var sum = (links: 0, empty: 0, notReference: 0, notAtStart: 0)
    let start = try! NSRegularExpression(pattern: #"^\s*(?:\[\d{1,4}\]|\(\d{1,4}\)|\d{1,4}\.?\s)"#)
    for path in paths {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { continue }
        let name = URL(fileURLWithPath: path).lastPathComponent.prefix(40)
        var targets: [(page: Int, point: CGPoint, knownX: Bool)] = []
        for p in 0..<document.pageCount {
            guard let page = document.page(at: p) else { continue }
            for link in PageLinks.links(on: page, in: document) {
                if case .place(let target, let point?) = link.target, target > p, let box = document.page(at: target)?.bounds(for: .cropBox) {
                    targets.append((target, point, point.x != box.minX))
                }
            }
        }
        if targets.isEmpty, let list = ReferenceList.find(in: document) {
            targets = list.entries.values.map { ($0.page, $0.point, true) }
        }
        var seen = Set<String>()
        var lines: [Int: [PreviewText.Line]] = [:]
        for target in targets.prefix(400) {
            let key = "\(target.page) \(Int(target.point.x)) \(Int(target.point.y))"
            guard seen.insert(key).inserted, let page = document.page(at: target.page) else { continue }
            let pageLines = lines[target.page] ?? PreviewText.lines(of: page)
            lines[target.page] = pageLines
            let entry = PreviewText.entry(in: pageLines, at: target.point, knownX: target.knownX)
            sum.links += 1
            let text = entry.map(\.text).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
            if entry.isEmpty { sum.empty += 1 } else if !PreviewText.looksLikeReference(entry) { sum.notReference += 1 }
            if !entry.isEmpty, start.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) == nil { sum.notAtStart += 1 }
            if paths.count == 1 || sum.links % 25 == 0 { print("\(name) p\(target.page + 1) [\(entry.count)] \(text.prefix(110))") }
        }
    }
    print("all: \(sum.links) targets, \(sum.empty) found nothing, \(sum.notReference) do not read like a reference, \(sum.notAtStart) do not start with a number")
}
