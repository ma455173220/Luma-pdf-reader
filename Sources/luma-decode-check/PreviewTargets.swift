import Foundation
import LumaCore
import PDFKit

// --preview-targets: where previews open, put right by what each link says (ADR 0006).
// For documents whose citations are worked out (their entries are known), each citation's preview
// place is compared with its entry: it should land on it. For documents that link their own citations
// and figures, how far the place found is from the place the link names, and how many found nothing.
func checkPreviewTargets(paths: [String]) {
    var decoded = (links: 0, onEntry: 0, off: 0, none: 0)
    var own = (citations: 0, citationFound: 0, figures: 0, figureFound: 0, moved: 0)
    var samples: [String] = []
    for path in paths {
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else { continue }
        let name = url.lastPathComponent.prefix(36)
        let preparation = CitationDecoder.prepare(fileAt: url)
        if let preparation, !preparation.linksItsOwnCitations, let list = preparation.list {
            let decoder = CitationDecoder(document: document, preparation: preparation)
            for p in 0...min(list.startPage, document.pageCount - 1) {
                guard let page = document.page(at: p) else { continue }
                for link in decoder.links(onPage: p) {
                    guard case .place(let target, let point?) = link.target else { continue }
                    decoded.links += 1
                    let text = page.selection(for: link.rect.insetBy(dx: 1, dy: 1))?.string ?? ""
                    guard let found = PreviewTarget.find(text: text, page: target, point: point, in: document, bodySize: preparation.bodySize, from: p) else {
                        decoded.none += 1; continue
                    }
                    printEntry(name, found)
                    if found.page == target && abs(found.point.y - point.y) < 4 && abs(found.point.x - point.x) < 6 { decoded.onEntry += 1 } else {
                        decoded.off += 1
                        if samples.count < 30 { samples.append("decoded \(name) p\(p + 1) \"\(text)\": entry at p\(target + 1) \(Int(point.x)),\(Int(point.y)), found p\(found.page + 1) \(Int(found.point.x)),\(Int(found.point.y))") }
                    }
                }
            }
            continue
        }
        for p in 0..<document.pageCount {
            guard let page = document.page(at: p) else { continue }
            for link in PageLinks.links(on: page, in: document) {
                guard case .place(let target, let point) = link.target, target != p || point != nil else { continue }
                let context = PreviewTarget.linkText(link.rect, on: page)
                let isFigure = context.range(of: #"(?:Fig(?:ure)?s?\.?|FIG(?:URE)?S?\.?|Tables?|TABLES?|Schemes?)\s*\S*$"#, options: .regularExpression) != nil
                let box = document.page(at: target)?.bounds(for: .cropBox) ?? .zero
                let found = PreviewTarget.find(text: context, page: target, point: point, in: document, bodySize: preparation?.bodySize, from: p)
                if isFigure { own.figures += 1; if found != nil { own.figureFound += 1 } }
                else if target > p, PreviewTarget.debugIsCitation(context) {
                    own.citations += 1; if found != nil { own.citationFound += 1 }
                    if let found { printEntry(name, found) }
                } else { continue }
                if let found, let point, abs(found.point.y - point.y) > 20 || found.page != target {
                    own.moved += 1
                    // One in every 60 moved, with the line found and the line at the named place.
                    if own.moved % 60 == 0, let shown = document.page(at: target) {
                        let named = PreviewText.lines(of: shown).min { abs($0.rect.maxY - point.y) < abs($1.rect.maxY - point.y) }?.text ?? ""
                        let at = found.entry.first?.text ?? "(figure or table, from p\(found.page + 1) y \(Int(found.point.y)))"
                        samples.append("own \(name) p\(p + 1) \"\(context.suffix(20))\" | named: \(named.prefix(40)) | found: \(at.prefix(50))")
                    }
                }
            }
        }
    }
    samples.forEach { print($0) }
    print("worked-out citations: \(decoded.links), preview on its entry \(decoded.onEntry), elsewhere \(decoded.off), nothing found \(decoded.none)")
    print("own links: citations \(own.citations) (entry found \(own.citationFound)), figures and tables \(own.figures) (caption found \(own.figureFound)); moved more than 20 points from the named place: \(own.moved)")
}

/// With LUMA_PRINT_ENTRIES set: every entry a citation's preview would copy, one line each, to compare
/// two versions of the entry reading.
private func printEntry(_ name: Substring, _ found: PreviewTarget.Found) {
    guard ProcessInfo.processInfo.environment["LUMA_PRINT_ENTRIES"] != nil else { return }
    print("entry \(name) p\(found.page + 1) \(Int(found.point.x)),\(Int(found.point.y)) [\(found.entry.count)] " + found.entry.map(\.text).joined(separator: " ").replacingOccurrences(of: "\n", with: " "))
}

/// With LUMA_DUMP_PAGE="path|page" (page from 1): the page's lines with where they are; with
/// LUMA_DUMP_LINKS as well, its links too.
func dumpPageLines() -> Bool {
    guard let spec = ProcessInfo.processInfo.environment["LUMA_DUMP_PAGE"], let bar = spec.lastIndex(of: "|"),
          let number = Int(spec[spec.index(after: bar)...]), let document = PDFDocument(url: URL(fileURLWithPath: String(spec[..<bar]))),
          let page = document.page(at: number - 1) else { return false }
    for line in PreviewText.lines(of: page) {
        let r = line.rect
        print("\(Int(r.minX))-\(Int(r.maxX)) y\(Int(r.minY))-\(Int(r.maxY)) | \(line.text.replacingOccurrences(of: "\n", with: " ").prefix(70))")
    }
    if ProcessInfo.processInfo.environment["LUMA_DUMP_LINKS"] != nil {
        for link in PageLinks.links(on: page, in: document) {
            let written = (page.selection(for: link.rect.insetBy(dx: 1, dy: 1))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            print("link \"\(written)\" x\(Int(link.rect.minX)) y\(Int(link.rect.minY)) -> \(link.target)")
        }
    }
    return true
}
