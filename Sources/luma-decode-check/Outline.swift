import Foundation
import LumaCore
import PDFKit

// Scores outlines worked out from the text against an answer key.
//
// Usage: luma-decode-check --outline <key folder> [document number]
//
// The key folder holds index.tsv (number, tab, path of the PDF) and one <number>.tsv per document,
// a heading per line: page (from 0), where the heading starts in that page's text, its depth (0 for
// the top level) or "-" for one that may be in the outline or not, and its title.
//
// A heading counts as right when the outline has an entry starting at it (or with the same title on
// the same page) at the same depth; wrong when its depth differs; missed when there is none. An entry
// that is no heading in the key is wrong too.

func checkOutlines(folder: URL, only: Int?) {
    let index = (try? String(contentsOf: folder.appendingPathComponent("index.tsv"), encoding: .utf8)) ?? ""
    var total = (headings: 0, right: 0, wrongDepth: 0, missed: 0, extra: 0)
    var problems: [String] = []
    func letters(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(24)) }
    for line in index.split(separator: "\n") {
        let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard fields.count == 2, let number = Int(fields[0]), only == nil || only == number,
              let keyText = try? String(contentsOf: folder.appendingPathComponent("\(number).tsv"), encoding: .utf8),
              let document = PDFDocument(url: URL(fileURLWithPath: fields[1])) else { continue }
        struct KeyHeading { let page: Int; let offset: Int; let depth: Int?; let title: String }
        let key = keyText.split(separator: "\n").compactMap { row -> KeyHeading? in
            let f = row.split(separator: "\t", maxSplits: 3).map(String.init)
            guard f.count == 4, let page = Int(f[0]), let offset = Int(f[1]) else { return nil }
            return KeyHeading(page: page, offset: offset, depth: Int(f[2]), title: f[3])
        }
        let started = Date()
        let found = OutlineDecoder.headings(of: document)
        let seconds = Date().timeIntervalSince(started)
        // An entry is matched by where it starts; by its title only when no heading starts there.
        func matches(_ h: OutlineDecoder.Heading, _ k: KeyHeading) -> Bool {
            guard h.page == k.page else { return false }
            if abs(h.offset - k.offset) <= 3 { return true }
            return letters(h.title) == letters(k.title) && !key.contains { $0.page == h.page && abs(h.offset - $0.offset) <= 3 }
        }
        var outcome = (headings: 0, right: 0, wrongDepth: 0, missed: 0, extra: 0)
        for k in key {
            guard let depth = k.depth else { continue }
            outcome.headings += 1
            if let h = found.first(where: { matches($0, k) }) {
                if h.depth == depth { outcome.right += 1 } else {
                    outcome.wrongDepth += 1
                    problems.append("\(number) p\(k.page + 1): \"\(k.title.prefix(50))\" at depth \(h.depth), not \(depth)")
                }
            } else {
                outcome.missed += 1
                if only != nil { problems.append("\(number) p\(k.page + 1): missed \"\(k.title.prefix(60))\"") }
            }
        }
        for h in found where !key.contains(where: { matches(h, $0) }) {
            outcome.extra += 1
            problems.append("\(number) p\(h.page + 1): \"\(h.title.prefix(60))\" (depth \(h.depth)) is no heading")
        }
        let percent = outcome.headings > 0 ? Double(outcome.right) / Double(outcome.headings) * 100 : 0
        print(String(format: "%2d: %3d headings, %3d right (%.1f%%), %2d at a wrong depth, %2d missed, %2d entries that are no heading | %.1f s",
                     number, outcome.headings, outcome.right, percent, outcome.wrongDepth, outcome.missed, outcome.extra, seconds))
        total.headings += outcome.headings; total.right += outcome.right; total.wrongDepth += outcome.wrongDepth
        total.missed += outcome.missed; total.extra += outcome.extra
    }
    let percent = total.headings > 0 ? Double(total.right) / Double(total.headings) * 100 : 0
    print(String(format: "all: %d headings, %d right (%.1f%%), %d at a wrong depth, %d missed, %d entries that are no heading",
                 total.headings, total.right, percent, total.wrongDepth, total.missed, total.extra))
    if !problems.isEmpty {
        print("\nproblems:")
        problems.forEach { print("  " + $0) }
    }
}

// Documents that carry their own outline: it is the answer. Decoding does not look at it; the
// outline worked out is compared with it. An entry agrees when the document's outline has one on the
// same page whose title starts the same way (letters and digits, numbering and case aside).
func checkLinkedOutlines(paths: [String]) {
    var sum = (documents: 0, withOwn: 0, own: 0, found: 0, agree: 0, decodedNothing: 0)
    var stray: [String] = []
    func key(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"^\s*(?:\d{1,2}(?:\.\d{1,2})*\.?|[IVX]{1,5}\.[A-H]?|[A-H]\.)\s*"#, with: "", options: .regularExpression)
        return String(t.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(16))
    }
    for path in paths {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { continue }
        sum.documents += 1
        let own = DocumentOutline.entries(of: document).filter { $0.page != nil }
        guard own.count >= 3 else { continue }
        sum.withOwn += 1
        let name = URL(fileURLWithPath: path).lastPathComponent.prefix(50)
        let found = OutlineDecoder.headings(of: document)
        if found.isEmpty { sum.decodedNothing += 1 }
        let agree = found.filter { h in own.contains { $0.page == h.page && !key($0.title).isEmpty && key($0.title) == key(h.title) } }
        for h in found where !agree.contains(h) {
            stray.append("\(name) p\(h.page + 1): \"\(h.title.prefix(60))\" not in its own outline")
        }
        let covered = own.filter { o in found.contains { $0.page == o.page && key($0.title) == key(o.title) } }.count
        print("\(name): own \(own.count), worked out \(found.count), agree \(agree.count), own entries found \(covered)")
        sum.own += own.count; sum.found += found.count; sum.agree += agree.count
    }
    print("all: \(sum.documents) documents, \(sum.withOwn) with an outline of 3 entries or more; own entries \(sum.own), worked out \(sum.found), agreeing \(sum.agree); nothing worked out for \(sum.decodedNothing)")
    if !stray.isEmpty {
        print("\nworked out but not in the document's own outline:")
        stray.forEach { print("  " + $0) }
    }
}
