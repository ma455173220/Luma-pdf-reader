import Foundation
import LumaCore
import PDFKit

// Scores the decoding of references to figures and tables against an answer key.
//
// Usage: luma-decode-check --figures <key folder> [document number]
//
// The key folder holds index.tsv (number, tab, path of the PDF) and one <number>.json per document:
// "captions" (type, label, page, rects of the caption's label) and "mentions" (page, rects: one per
// line, text, targets: type and label of each figure or table named). A label is the number as
// written, "S3" for supplementary material and "X3" for a number after "Supplementary"; Roman numerals
// are given as numbers. Pages count from 0; rectangles are [x, y, width, height] in page coordinates.
//
// A link leads to the caption it lands on or above: the nearest caption on the target page whose top
// is no higher than the point, starting near the same left edge. A mention counts as right when its
// links all lead to figures or tables it names and every one it names that the file has gets a link;
// wrong when any leads elsewhere; missed when it has no link, short when some named one has none.

struct FigureKey: Decodable {
    struct Caption: Decodable { let type: String; let label: String; let page: Int; let rects: [[Double]] }
    struct Target: Decodable, Hashable { let type: String; let label: String }
    struct Mention: Decodable { let page: Int; let rects: [[Double]]; let text: String; let targets: [Target] }
    let captions: [Caption]
    let mentions: [Mention]
}

func checkFigures(folder: URL, only: Int?) {
    let index = (try? String(contentsOf: folder.appendingPathComponent("index.tsv"), encoding: .utf8)) ?? ""
    var total = (gradeable: 0, right: 0, wrong: 0, missed: 0, short: 0, stray: 0, noAnswer: 0, noAnswerShown: 0)
    var problems: [String] = []
    for line in index.split(separator: "\n") {
        let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard fields.count == 2, let number = Int(fields[0]), only == nil || only == number else { continue }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(number).json")),
              let key = try? JSONDecoder().decode(FigureKey.self, from: data),
              let document = PDFDocument(url: URL(fileURLWithPath: fields[1])) else {
            print("\(number): cannot read the document or its key")
            continue
        }
        let started = Date()
        // As the reader sets it up: with the size of the running text found while preparing.
        let decoder = FigureDecoder(document: document, bodySize: CitationDecoder.prepare(fileAt: URL(fileURLWithPath: fields[1]))?.bodySize)
        let captioned = Set(key.captions.map { FigureKey.Target(type: $0.type, label: $0.label) })
        // The caption a link lands on or above. A figure filling a page has its caption at the head of
        // the next page.
        func landing(_ target: PageLink.Target) -> FigureKey.Target? {
            guard case .place(let page, let point?) = target else { return nil }
            let below = key.captions.filter { c in
                let r = rect(c.rects[0])
                return c.page == page && r.maxY <= point.y + 3 && abs(r.minX - point.x) <= 60
            }.min { rect($0.rects[0]).maxY > rect($1.rects[0]).maxY }
            let height = document.page(at: page + 1)?.bounds(for: .cropBox).height ?? 0
            let headOfNext = key.captions.filter { $0.page == page + 1 && rect($0.rects[0]).maxY >= height * 0.8 }
                .max { rect($0.rects[0]).maxY < rect($1.rects[0]).maxY }
            return (below ?? headOfNext).map { FigureKey.Target(type: $0.type, label: $0.label) }
        }
        var outcome = (gradeable: 0, right: 0, wrong: 0, missed: 0, short: 0, stray: 0, noAnswer: 0, noAnswerShown: 0)
        var linksByPage: [Int: [PageLink]] = [:]
        for p in 0..<document.pageCount { linksByPage[p] = decoder.links(onPage: p) }
        var used = Set<String>()
        for mention in key.mentions {
            let boxes = mention.rects.map { rect($0).insetBy(dx: -1, dy: 0) }
            let over = (linksByPage[mention.page] ?? []).enumerated().filter { item in
                boxes.contains { $0.contains(CGPoint(x: item.element.rect.midX, y: item.element.rect.midY)) }
            }
            over.forEach { used.insert("\(mention.page)-\($0.offset)") }
            let leads = over.map { landing($0.element.target) }
            let text = mention.text.replacingOccurrences(of: "\n", with: "⏎")
            let named = Set(mention.targets).intersection(captioned)
            if named.isEmpty {
                outcome.noAnswer += 1
                if !over.isEmpty {
                    outcome.noAnswerShown += 1
                    problems.append("\(number) p\(mention.page + 1): \"\(text)\" names nothing the file has, but leads to \(leads.map { $0.map { "\($0.type) \($0.label)" } ?? "?" })")
                }
                continue
            }
            outcome.gradeable += 1
            if over.isEmpty {
                outcome.missed += 1
                if only != nil { problems.append("\(number) p\(mention.page + 1): missed \"\(text)\"") }
            } else if !leads.allSatisfy({ $0.map(named.contains) ?? false }) {
                outcome.wrong += 1
                problems.append("\(number) p\(mention.page + 1): \"\(text)\" leads to \(leads.map { $0.map { "\($0.type) \($0.label)" } ?? "?" })")
            } else if Set(leads.compactMap { $0 }) != named {
                outcome.short += 1
                if only != nil { problems.append("\(number) p\(mention.page + 1): short \"\(text)\"") }
            } else {
                outcome.right += 1
            }
        }
        for (p, links) in linksByPage.sorted(by: { $0.key < $1.key }) {
            for (i, link) in links.enumerated() where !used.contains("\(p)-\(i)") {
                outcome.stray += 1
                let text = document.page(at: p)?.selection(for: link.rect.insetBy(dx: 1, dy: 1))?.string ?? ""
                problems.append("\(number) p\(p + 1): no mention in the key at \(Int(link.rect.minX)),\(Int(link.rect.minY)) \"\(text.replacingOccurrences(of: "\n", with: "⏎"))\", leads to \(landing(link.target).map { "\($0.type) \($0.label)" } ?? "?")")
            }
        }
        let percent = outcome.gradeable > 0 ? Double(outcome.right) / Double(outcome.gradeable) * 100 : 0
        print(String(format: "%2d: %4d mentions, %4d right (%.1f%%), %3d wrong, %3d missed, %3d short, %3d stray | unanswerable %d, shown %d | %.1f s",
                     number, outcome.gradeable, outcome.right, percent, outcome.wrong, outcome.missed, outcome.short, outcome.stray,
                     outcome.noAnswer, outcome.noAnswerShown, Date().timeIntervalSince(started)))
        total.gradeable += outcome.gradeable; total.right += outcome.right; total.wrong += outcome.wrong; total.missed += outcome.missed
        total.short += outcome.short; total.stray += outcome.stray; total.noAnswer += outcome.noAnswer; total.noAnswerShown += outcome.noAnswerShown
    }
    let percent = total.gradeable > 0 ? Double(total.right) / Double(total.gradeable) * 100 : 0
    print(String(format: "all: %d mentions, %d right (%.1f%%), %d wrong, %d missed, %d short, %d stray links | unanswerable %d, shown %d",
                 total.gradeable, total.right, percent, total.wrong, total.missed, total.short, total.stray, total.noAnswer, total.noAnswerShown))
    if !problems.isEmpty {
        print("\nproblems:")
        for problem in problems { print("  " + problem) }
    }
}

// Documents that carry their own links to figures and tables: those links are the answers. A link is
// taken as one to a figure or table when the text under it starts with the word ("Fig. 3", "Table 2").
// Decoding does not look at them; its links are compared with theirs: the same page, or the page
// before when the figure fills it.
func checkLinkedFigures(paths: [String]) {
    var sum = (documents: 0, withOwn: 0, own: 0, agree: 0, disagree: 0, missed: 0)
    var disagreements: [String] = []
    let word = try! NSRegularExpression(pattern: #"^\s*(?:Fig(?:ure)?s?\.?|FIG(?:URE)?S?\.?|Tables?|TABLES?|Schemes?|SCHEMES?)\s*\d"#)
    for path in paths {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { continue }
        sum.documents += 1
        let name = URL(fileURLWithPath: path).lastPathComponent.prefix(50)
        // As the reader does for a document that links its own citations: a decoder reading a document
        // of its own, let go of after every page here so that opening it again is tried as well.
        let file = URL(fileURLWithPath: path)
        let reader = TextReader(file: file, pageCount: document.pageCount)
        let decoder = FigureDecoder(reading: reader, pageCount: document.pageCount, bodySize: CitationDecoder.prepare(fileAt: file)?.bodySize)
        var outcome = (own: 0, agree: 0, disagree: 0, missed: 0)
        for p in 0..<document.pageCount {
            guard let page = document.page(at: p) else { continue }
            let own = PageLinks.links(on: page, in: document).filter { link in
                guard case .place = link.target, let text = page.selection(for: link.rect)?.string else { return false }
                return word.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
            }
            guard !own.isEmpty else { continue }
            let decoded = decoder.links(onPage: p)
            reader.letGo()
            for link in own {
                outcome.own += 1
                let over = decoded.filter { link.rect.insetBy(dx: -2, dy: -1).contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                guard let first = over.first else {
                    outcome.missed += 1
                    // With a single document, say which.
                    if paths.count == 1 { print("  missed p\(p + 1) \"\(page.selection(for: link.rect)?.string ?? "")\"") }
                    continue
                }
                guard case .place(let ownPage, _) = link.target, case .place(let page, _) = first.target else { continue }
                if page == ownPage || page == ownPage - 1 || page == ownPage + 1 && over.count == 1 { outcome.agree += 1 } else {
                    outcome.disagree += 1
                    let text = document.page(at: p)?.selection(for: link.rect)?.string ?? ""
                    disagreements.append("\(name) p\(p + 1) \"\(text.prefix(24))\": own link to p\(ownPage + 1), decoded p\(page + 1)")
                }
            }
        }
        if outcome.own > 0 {
            sum.withOwn += 1
            print("\(name): \(outcome.own) own figure links, \(outcome.agree) agree, \(outcome.disagree) disagree, \(outcome.missed) missed")
        }
        sum.own += outcome.own; sum.agree += outcome.agree; sum.disagree += outcome.disagree; sum.missed += outcome.missed
    }
    print("all: \(sum.documents) documents, \(sum.withOwn) with own figure links; \(sum.own) links: \(sum.agree) agree, \(sum.disagree) disagree, \(sum.missed) missed")
    if !disagreements.isEmpty {
        print("\ndisagreements:")
        disagreements.forEach { print("  " + $0) }
    }
}
