import Foundation
import LumaCore
import PDFKit

// Scores citation decoding against an answer key.
//
// Usage: luma-decode-check <key folder> [document number]
//
// The key folder holds index.tsv (number, tab, path of the PDF) and one <number>.json per document:
// "markers" (page, rect, targets: the entry numbers a citation names) and "entries" (n, page, rect of
// the entry's label). Pages count from 0; rectangles are [x, y, width, height] in page coordinates.
//
// A citation counts as right when the links worked out over it all lead to one of the entries it
// names; wrong when any leads elsewhere; missed when there is none. A link where the key has no
// citation is wrong too. Citations naming an entry the file does not have cannot be right; a link
// there is wrong, and none is as it should be.

struct Key: Decodable {
    /// `rects`: one per line the citation is on.
    struct Marker: Decodable { let page: Int; let rect: [Double]; let rects: [[Double]]?; let targets: [Int] }
    struct Entry: Decodable { let n: Int; let page: Int; let rect: [Double] }
    let markers: [Marker]
    let entries: [Entry]
}

func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: luma-decode-check <key folder> [document number]")
    print("       luma-decode-check --linked <file listing PDFs, one path per line>")
    print("       luma-decode-check --figures <key folder> [document number]")
    print("       luma-decode-check --figures-linked <file listing PDFs, one path per line>")
    print("       luma-decode-check --outline <key folder> [document number]")
    print("       luma-decode-check --outline-linked <file listing PDFs, one path per line>")
    exit(2)
}

if arguments[1] == "--outline-linked", arguments.count >= 3 {
    checkLinkedOutlines(paths: ((try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    exit(0)
}
if arguments[1] == "--outline", arguments.count >= 3 {
    checkOutlines(folder: URL(fileURLWithPath: arguments[2]), only: arguments.count > 3 ? Int(arguments[3]) : nil)
    exit(0)
}
if arguments[1] == "--preview-targets", arguments.count >= 3 {
    checkPreviewTargets(paths: ((try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    exit(0)
}
if dumpPageLines() { exit(0) }
if arguments[1] == "--preview-entries", arguments.count >= 3 {
    checkPreviewEntries(paths: ((try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    exit(0)
}
if arguments[1] == "--figures-linked", arguments.count >= 3 {
    checkLinkedFigures(paths: ((try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    exit(0)
}
if arguments[1] == "--figures", arguments.count >= 3 {
    checkFigures(folder: URL(fileURLWithPath: arguments[2]), only: arguments.count > 3 ? Int(arguments[3]) : nil)
    exit(0)
}

// What decoding makes of one document: its reference list and the citations on a page.
if arguments[1] == "--explain", arguments.count >= 4, let document = PDFDocument(url: URL(fileURLWithPath: arguments[2])), let page = Int(arguments[3]) {
    let decoder = CitationDecoder(document: document)
    var clock = Date()
    guard let list = decoder.referenceList else { print("no numbered reference list found"); exit(0) }
    let listTime = Date().timeIntervalSince(clock)
    clock = Date()
    _ = decoder.links(onPage: page - 1)
    print(String(format: "time: list %.0f ms, first page %.0f ms", listTime * 1000, Date().timeIntervalSince(clock) * 1000))
    clock = Date()
    for p in 0..<min(document.pageCount, list.startPage + 1) where p != page - 1 { _ = decoder.links(onPage: p) }
    print(String(format: "time: other %d pages %.0f ms", min(document.pageCount, list.startPage + 1) - 1, Date().timeIntervalSince(clock) * 1000))
    let numbers = list.entries.keys.sorted()
    print("list: \(list.count) entries (\(numbers.first ?? 0)…\(numbers.last ?? 0)), \(list.style), starts on page \(list.startPage + 1) at \(list.startOffset)")
    for marker in decoder.markers(onPage: page - 1) {
        let text = (document.page(at: page - 1)?.string as NSString?)?.substring(with: marker.range) ?? ""
        print("  \(text.replacingOccurrences(of: "\n", with: "⏎")) -> \(marker.numbers)")
    }
    exit(0)
}

// Documents that carry their own links: those links are the answers. Decoding does not look at them;
// its links are compared with theirs. A citation link is one that leads into the reference list.
if arguments[1] == "--linked" {
    let paths = ((try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    var sum = (links: 0, agree: 0, disagree: 0, missed: 0, extra: 0, withList: 0, documents: 0)
    var disagreements: [String] = []
    for path in paths {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { continue }
        let name = URL(fileURLWithPath: path).lastPathComponent.prefix(50)
        let decoder = CitationDecoder(document: document)
        guard let list = decoder.referenceList else {
            // No numbered list found: an author-year paper, or a list the finder cannot read.
            var cited = 0
            for p in 0..<document.pageCount {
                guard let page = document.page(at: p) else { continue }
                cited += PageLinks.links(on: page, in: document).filter { if case .place(let t, _) = $0.target { return t > p } else { return false } }.count
            }
            print("\(name): no numbered list found; \(cited) links to later pages left to the document's own")
            sum.documents += 1
            continue
        }
        sum.documents += 1; sum.withList += 1
        var outcome = (links: 0, agree: 0, disagree: 0, missed: 0, extra: 0)
        // Some documents' own links land a fixed distance above the entry (LaTeX raises its anchors so
        // that a jump shows a little of what is above). That distance is learnt from the document:
        // the most common difference between its own links and the decoded ones.
        var differences: [Int: Int] = [:]
        for p in 0...list.startPage {
            guard let page = document.page(at: p) else { continue }
            let decoded = decoder.links(onPage: p)
            for link in PageLinks.links(on: page, in: document) {
                guard case .place(let ownPage, let ownPoint?) = link.target, ownPage >= list.startPage else { continue }
                for item in decoded where link.rect.insetBy(dx: -1, dy: 0).contains(CGPoint(x: item.rect.midX, y: item.rect.midY)) {
                    if case .place(let page, let point?) = item.target, page == ownPage {
                        differences[Int(((ownPoint.y - point.y) / 4).rounded()), default: 0] += 1
                    }
                }
            }
        }
        let shift = CGFloat((differences.max { $0.value < $1.value }?.key ?? 0) * 4)
        for p in 0...list.startPage {
            guard let page = document.page(at: p) else { continue }
            // The document's own links into the reference list.
            let own = PageLinks.links(on: page, in: document).filter {
                if case .place(let t, _) = $0.target { return t >= list.startPage } else { return false }
            }
            let decoded = decoder.links(onPage: p)
            var matched = Set<Int>()
            for link in own {
                outcome.links += 1
                let over = decoded.enumerated().filter { link.rect.insetBy(dx: -1, dy: 0).contains(CGPoint(x: $0.element.rect.midX, y: $0.element.rect.midY)) }
                guard !over.isEmpty else {
                    outcome.missed += 1
                    // With a single document, say which.
                    if paths.count == 1, outcome.missed <= 12 {
                        let text = page.string as NSString? ?? ""
                        let k = page.characterIndex(at: CGPoint(x: link.rect.midX, y: link.rect.midY))
                        let around = k >= 0 ? text.substring(with: NSRange(location: max(0, k - 25), length: min(40, text.length - max(0, k - 25)))) : ""
                        print("  missed p\(p + 1) \"\(page.selection(for: link.rect)?.string ?? "")\" near \(around.replacingOccurrences(of: "\n", with: "⏎"))")
                    }
                    continue
                }
                over.forEach { matched.insert($0.offset) }
                guard case .place(let ownPage, let ownPoint) = link.target else { continue }
                // One own link over several decoded numbers ("[1–3]" linked as a whole) leads to one of
                // them, so agreeing with any one of them is agreeing.
                func leadsTheSameWay(_ item: (offset: Int, element: PageLink)) -> Bool {
                    guard case .place(let page, let point) = item.element.target else { return false }
                    // An entry at the top of a page whose raised anchor fell to the foot of the page before.
                    // Likewise at the top of the second column, the anchor falling to the foot of the first.
                    if page == ownPage + 1 || page == ownPage, let ownPoint, let point, ownPoint.y < 130,
                       let height = document.page(at: page)?.bounds(for: .cropBox).maxY, point.y > height - 140 { return true }
                    guard page == ownPage else { return false }
                    guard let ownPoint, let point else { return true }
                    return abs(ownPoint.y - point.y - shift) <= 12
                }
                let same = over.count == 1 ? leadsTheSameWay(over[0]) : over.contains(where: leadsTheSameWay)
                if same { outcome.agree += 1 } else {
                    outcome.disagree += 1
                    let text = page.selection(for: link.rect)?.string ?? ""
                    disagreements.append("\(name) p\(p + 1) \"\(text.prefix(20))\": own link to p\(ownPage + 1) \(ownPoint.map { "y \(Int($0.y))" } ?? ""), decoded \(over.map { item -> String in if case .place(let pg, let pt) = item.element.target { return "p\(pg + 1) y \(pt.map { Int($0.y) } ?? -1)" }; return "?" })")
                }
            }
            outcome.extra += decoded.count - matched.count
            // A few of them, to look at.
            if let sample = ProcessInfo.processInfo.environment["EXTRA_SAMPLE"], let every = Int(sample), every > 0 {
                for (i, link) in decoded.enumerated() where !matched.contains(i) && (p * 31 + i) % every == 0 {
                    if let marker = decoder.markers(onPage: p).first(where: { $0.rect.intersects(link.rect) }), let t = page.string as NSString? {
                        let a = max(0, marker.range.location - 35), b = min(t.length, marker.range.location + marker.range.length + 15)
                        print("  extra p\(p + 1): " + (t.substring(with: NSRange(location: a, length: marker.range.location - a)) + "⟦" + t.substring(with: marker.range) + "⟧" + t.substring(with: NSRange(location: marker.range.location + marker.range.length, length: b - marker.range.location - marker.range.length))).replacingOccurrences(of: "\n", with: "⏎"))
                    }
                }
            }
        }
        print("\(name): \(outcome.links) own citation links, \(outcome.agree) agree, \(outcome.disagree) disagree, \(outcome.missed) missed, \(outcome.extra) decoded where the document has none")
        sum.links += outcome.links; sum.agree += outcome.agree; sum.disagree += outcome.disagree
        sum.missed += outcome.missed; sum.extra += outcome.extra
    }
    print("all: \(sum.documents) documents, \(sum.withList) with a numbered list found; \(sum.links) own citation links: \(sum.agree) agree, \(sum.disagree) disagree, \(sum.missed) missed; \(sum.extra) decoded where the document has none")
    if !disagreements.isEmpty {
        print("\ndisagreements:")
        disagreements.forEach { print("  " + $0) }
    }
    exit(0)
}
let folder = URL(fileURLWithPath: arguments[1])
let only = arguments.count > 2 ? Int(arguments[2]) : nil
let index = (try? String(contentsOf: folder.appendingPathComponent("index.tsv"), encoding: .utf8)) ?? ""

var total = (gradeable: 0, right: 0, wrong: 0, missed: 0, stray: 0, noAnswer: 0, noAnswerShown: 0)
var problems: [String] = []

for line in index.split(separator: "\n") {
    let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard fields.count == 2, let number = Int(fields[0]), only == nil || only == number else { continue }
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(number).json")),
          let key = try? JSONDecoder().decode(Key.self, from: data),
          let document = PDFDocument(url: URL(fileURLWithPath: fields[1])) else {
        print("\(number): cannot read the document or its key")
        continue
    }
    let started = Date()
    let decoder = CitationDecoder(document: document)
    let entries = Dictionary(key.entries.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
    // Which key entry a link leads to: the one whose label is nearest to where it points, within a line or so.
    func entryNumber(page: Int, point: CGPoint?) -> Int? {
        guard let point else { return nil }
        return key.entries.filter { e in
            let r = rect(e.rect)
            return e.page == page && abs(point.x - r.minX) <= 15 && abs(point.y - r.maxY) <= 15
        }.min { a, b in
            hypot(point.x - rect(a.rect).minX, point.y - rect(a.rect).maxY) < hypot(point.x - rect(b.rect).minX, point.y - rect(b.rect).maxY)
        }?.n
    }

    var outcome = (gradeable: 0, right: 0, wrong: 0, missed: 0, stray: 0, noAnswer: 0, noAnswerShown: 0)
    var linksByPage: [Int: [PageLink]] = [:]
    for p in 0..<document.pageCount { linksByPage[p] = decoder.links(onPage: p) }
    var used = Set<String>()
    for marker in key.markers {
        // A link is over a citation when its middle is: links on the lines above and below can touch it.
        let boxes = (marker.rects ?? [marker.rect]).map { rect($0).insetBy(dx: -1, dy: 0) }
        let over = (linksByPage[marker.page] ?? []).enumerated().filter { item in
            boxes.contains { $0.contains(CGPoint(x: item.element.rect.midX, y: item.element.rect.midY)) }
        }
        over.forEach { used.insert("\(marker.page)-\($0.offset)") }
        let answerable = marker.targets.allSatisfy { entries[$0] != nil }
        let leads: [Int?] = over.map { item in
            if case .place(let page, let point) = item.element.target { return entryNumber(page: page, point: point) }
            return nil
        }
        if !answerable {
            outcome.noAnswer += 1
            if !over.isEmpty {
                outcome.noAnswerShown += 1
                problems.append("\(number) p\(marker.page + 1): names \(marker.targets), not all in the file, but leads to \(leads.map { $0.map(String.init) ?? "?" })")
            }
            continue
        }
        outcome.gradeable += 1
        if over.isEmpty {
            outcome.missed += 1
            if only != nil {
                let text = document.page(at: marker.page)?.selection(for: rect(marker.rect))?.string ?? ""
                problems.append("\(number) p\(marker.page + 1): missed \(marker.targets) \"\(text.prefix(40))\"")
            }
        } else if leads.allSatisfy({ $0.map(marker.targets.contains) ?? false }) {
            outcome.right += 1
        } else {
            outcome.wrong += 1
            problems.append("\(number) p\(marker.page + 1): names \(marker.targets), leads to \(leads.map { $0.map(String.init) ?? "?" })")
        }
    }
    // Links where the key has no citation at all.
    for (p, links) in linksByPage {
        for (i, link) in links.enumerated() where !used.contains("\(p)-\(i)") {
            outcome.stray += 1
            var lead = "?"
            if case .place(let page, let point) = link.target { lead = entryNumber(page: page, point: point).map(String.init) ?? "?" }
            // The citation's text, with some of what stands around it.
            var text = document.page(at: p)?.selection(for: link.rect)?.string ?? ""
            if let marker = decoder.markers(onPage: p).first(where: { $0.rect.intersects(link.rect) }),
               let pageText = document.page(at: p)?.string as NSString? {
                let a = max(0, marker.range.location - 30), b = min(pageText.length, marker.range.location + marker.range.length + 15)
                text = (pageText.substring(with: NSRange(location: a, length: marker.range.location - a)) + "⟦"
                    + pageText.substring(with: marker.range) + "⟧" + pageText.substring(with: NSRange(location: marker.range.location + marker.range.length, length: b - marker.range.location - marker.range.length)))
                    .replacingOccurrences(of: "\n", with: "⏎")
            }
            problems.append("\(number) p\(p + 1): no citation in the key at \(Int(link.rect.minX)),\(Int(link.rect.minY)) \"\(text)\", leads to \(lead)")
        }
    }
    let list = decoder.referenceList
    let found = list?.count ?? 0
    let misplaced = (list?.entries.values ?? [:].values).filter { e in
        guard let k = entries[e.number] else { return true }
        return k.page != e.page || abs(rect(k.rect).minX - e.labelRect.minX) > 3 || abs(rect(k.rect).maxY - e.labelRect.maxY) > 3
    }.count
    let percent = outcome.gradeable > 0 ? Double(outcome.right) / Double(outcome.gradeable) * 100 : 0
    print(String(format: "%2d: %4d citations, %4d right (%.1f%%), %3d wrong, %3d missed, %3d stray | unanswerable %d, shown %d | entries %d of %d, %d misplaced | %.1f s",
                 number, outcome.gradeable, outcome.right, percent, outcome.wrong, outcome.missed, outcome.stray,
                 outcome.noAnswer, outcome.noAnswerShown, found, key.entries.count, misplaced, Date().timeIntervalSince(started)))
    total.gradeable += outcome.gradeable; total.right += outcome.right; total.wrong += outcome.wrong
    total.missed += outcome.missed; total.stray += outcome.stray; total.noAnswer += outcome.noAnswer; total.noAnswerShown += outcome.noAnswerShown
}
let percent = total.gradeable > 0 ? Double(total.right) / Double(total.gradeable) * 100 : 0
print(String(format: "all: %d citations, %d right (%.1f%%), %d wrong, %d missed, %d stray links | unanswerable %d, shown %d",
             total.gradeable, total.right, percent, total.wrong, total.missed, total.stray, total.noAnswer, total.noAnswerShown))
if !problems.isEmpty {
    print("\nwrong and stray:")
    for problem in problems { print("  " + problem) }
}
