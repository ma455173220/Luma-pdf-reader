import AppKit
import Foundation
import LumaCore
import PDFKit

// `luma-corpus-check --pages <scratch-dir> <mupdf-pages.py> <file> [more files...]`
//
// Runs the page writer over real PDFs and checks every result with three independent readers.
// For each file it saves three times, each save on top of the one before:
//   1. turns: the first page a quarter turn, the middle page a half turn, the last page three quarters;
//   2. removes the middle page and swaps the first and the last;
//   3. inserts the first page of the next file in the list after the first page (turned a quarter),
//      and appends that whole file (its first five pages if it has more than 40).
// Every result is compared, page by page, with the page it was made from — in the original or in
// the file inserted from:
//   · the previous bytes are an exact prefix of the new file;
//   · system engine: page count, text, page size and turn, annotations; and the page drawn upright
//     is pixel-for-pixel the same as the page it came from drawn upright;
//   · poppler: text, page size and turn, no new messages, and rendering: exact for every page, a
//     turned page being drawn from a copy of the result with its old turn given back;
//   · MuPDF: text, page size and turn, annotations, links (leading to where their page went now, or
//     gone with a removed page), form controls, outline, no new warnings, no newly needed repair.
// What an inserted page leaves behind by design — links within its own document, form fields and
// their pop-ups — is not counted as lost.
// Originals are only read. Everything written goes to the scratch directory and is deleted.

/// Where a page of a result comes from: the file (0 = the original, 1 = the file inserted from),
/// its page there, and the turn it must have now.
struct Origin: Equatable {
    let doc: Int
    let page: Int
    let rotation: Int
}

/// Everything the three readers say about one file, read once.
final class Readings {
    let url: URL
    let pdf: PDFDocument
    let text: [String]
    let sizes: [String]
    let rotations: [Int]
    let pictures: [Picture]
    let messages: Set<String>
    let mupdf: [String: Any]
    /// Per page, the page each of its links leads to as the system engine reads it (nil: nowhere it knows).
    let linkTargets: [[Int?]]
    /// Per page, whether it carries annotations an inserted copy leaves behind by design: form fields,
    /// links within the document, and their pop-ups. Such a page draws differently once inserted.
    let leavesAnnotationsBehind: [Bool]
    /// The outline as the system engine reads it: whether each entry leads nowhere in the document.
    let outlineLeadsNowhere: [Bool]
    private var hiddenPictures: [Picture]?

    private var withoutIntents: (pictures: [Picture], hidden: [Picture])?

    var hasOutputIntents: Bool { (mupdf["outputIntents"] as? Bool) == true }

    /// poppler's renderings with annotations hidden, read the first time they are needed.
    func picturesWithoutAnnotations(scratch: URL) -> [Picture] {
        if let hiddenPictures { return hiddenPictures }
        let rendered = splitPGM(run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", "-hide-annotations", url.path], in: scratch).output)
        hiddenPictures = rendered
        return rendered
    }

    /// poppler's renderings of a copy without the document's colour profile for output: how the
    /// pages look once inserted into a document that has none. With and without annotations.
    func picturesWithoutOutputIntents(scratch: URL, helper: String) -> (pictures: [Picture], hidden: [Picture]) {
        if let withoutIntents { return withoutIntents }
        let copy = scratch.appendingPathComponent("without-intents-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: copy) }
        var result: (pictures: [Picture], hidden: [Picture]) = ([], [])
        if run(python, ["-I", helper, "--without-output-intents", url.path, copy.path], in: scratch).status == 0 {
            result.pictures = splitPGM(run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", copy.path], in: scratch).output)
            result.hidden = splitPGM(run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", "-hide-annotations", copy.path], in: scratch).output)
        }
        withoutIntents = result
        return result
    }

    init?(_ url: URL, scratch: URL, helper: String) {
        guard let pdf = PDFDocument(url: url) else { return nil }
        self.url = url
        self.pdf = pdf
        let readings = popplerReadings(url, scratch: scratch)
        guard let readings, readings.text.count == pdf.pageCount, readings.sizes.count == pdf.pageCount,
              readings.pictures.count == pdf.pageCount else { return nil }
        text = readings.text
        sizes = readings.sizes
        rotations = readings.rotations
        pictures = readings.pictures
        messages = readings.messages
        let report = run(python, ["-I", helper, url.path], in: scratch)
        guard let parsed = try? JSONSerialization.jsonObject(with: report.output) as? [[String: Any]], parsed.count == 1,
              (parsed[0]["ok"] as? Bool) == true else { return nil }
        mupdf = parsed[0]
        // As either reader sees it: the system engine cannot follow some named destinations that
        // MuPDF can, and the other way round.
        let mupdfPages = parsed[0]["pages"] as? [[String: Any]] ?? []
        leavesAnnotationsBehind = (0..<pdf.pageCount).map { index in
            let systemSees = (pdf.page(at: index)?.annotations ?? []).contains { annotation in
                annotation.type == "Widget" || (annotation.type == "Link" && (annotation.destination != nil || annotation.action is PDFActionGoTo))
            }
            let report = index < mupdfPages.count ? mupdfPages[index] : [:]
            let mupdfSees = !((report["controls"] as? [Any])?.isEmpty ?? true)
                || (report["links"] as? [[Any]] ?? []).contains { ($0.last as? String).map { $0.hasPrefix("page:") || $0 == "kind:4" } ?? false }
            return systemSees || mupdfSees
        }
        outlineLeadsNowhere = DocumentOutline.entries(of: pdf).map { $0.page == nil }
        linkTargets = (0..<pdf.pageCount).map { index in
            (pdf.page(at: index)?.annotations ?? []).filter { $0.type == "Link" }.map { link -> Int? in
                guard let target = link.destination?.page ?? (link.action as? PDFActionGoTo)?.destination.page else { return nil }
                let found = pdf.index(for: target)
                return found == NSNotFound ? nil : found
            }
        }
    }

    var mupdfPages: [[String: Any]] { mupdf["pages"] as? [[String: Any]] ?? [] }
}

/// poppler's text (one entry per page), page sizes and turns, renderings, and every message it printed.
func popplerReadings(_ url: URL, scratch: URL) -> (text: [String], sizes: [String], rotations: [Int], pictures: [Picture], messages: Set<String>)? {
    let text = run("\(popplerDirectory)/pdftotext", [url.path, "-"], in: scratch)
    let info = run("\(popplerDirectory)/pdfinfo", ["-f", "1", "-l", "100000", url.path], in: scratch)
    let render = run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", url.path], in: scratch)
    guard text.launched, info.launched, render.launched, text.status == 0, info.status == 0, render.status == 0 else { return nil }
    var pages = String(decoding: text.output, as: UTF8.self).components(separatedBy: "\u{0C}")
    if pages.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { pages.removeLast() }
    var sizes: [String] = [], rotations: [Int] = []
    for line in String(decoding: info.output, as: UTF8.self).split(separator: "\n") where line.hasPrefix("Page ") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        if parts[0].hasSuffix("size") { sizes.append(parts[1]) }
        if parts[0].hasSuffix("rot") { rotations.append(Int(parts[1]) ?? -1) }
    }
    let messages = Set((text.messages + info.messages + render.messages).split(separator: "\n").map(String.init))
    return (pages, sizes, rotations, splitPGM(render.output), messages)
}

/// The page drawn as if upright, so that a turned page can be compared with the one it came from.
/// Turns the page in `document`, which must be a copy opened for drawing only.
func renderUpright(_ document: PDFDocument?, page index: Int, hidingAnnotations: Bool = false) -> Picture? {
    guard let page = document?.page(at: index) else { return nil }
    page.rotation = 0
    if hidingAnnotations { page.annotations.forEach { $0.shouldDisplay = false } }
    return render(page, scale: 0.5)
}

func sortedCharacters(_ text: String) -> String { String(text.filter { !$0.isWhitespace }.sorted()) }

/// poppler's text of one page of a file after MuPDF's own writer turned that page.
func popplerTextTurnedByMuPDF(_ url: URL, page: Int, rotation: Int, scratch: URL, helper: String) -> String? {
    let copy = scratch.appendingPathComponent("turned-by-mupdf-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: copy) }
    let turned = run(python, ["-I", helper, "--turn", url.path, copy.path, "\(page)", "\(rotation)"], in: scratch)
    guard turned.status == 0 else { return nil }
    let text = run("\(popplerDirectory)/pdftotext", ["-f", "\(page + 1)", "-l", "\(page + 1)", copy.path, "-"], in: scratch)
    guard text.status == 0 else { return nil }
    return String(decoding: text.output, as: UTF8.self).replacingOccurrences(of: "\u{0C}", with: "")
}

/// Statistics over the whole run.
var orderOnlyText = 0
var turnedRenderingsCompared = 0
var unstableReadings = 0
var turnedReadingsMatchingMuPDF = 0
var structureOrderOnly = 0
var intentPagesCompared = 0
var annotationsOrderOnly = 0
let debugging = ProcessInfo.processInfo.environment["LUMA_PAGES_DEBUG"] != nil

/// Compares one result with the pages it was made from. Returns every problem found.
/// `previous`: the file appended to, whose bytes must start the result; nil for a new file (a slim
/// copy). `structureLeftBehind`: every page lost its structure information, as in a slim copy.
func checkPageEdit(result: Data, previous: Data?, origins: [Origin], docs: [Readings], scratch: URL, helper: String, tag: String,
                   structureLeftBehind: Bool = false) -> [String] {
    var problems: [String] = []
    // A save that changes nothing (one page cannot be reordered) leaves the file as it was.
    if let previous, result != previous && !(result.count > previous.count && result.prefix(previous.count) == previous) {
        problems.append("previous bytes not preserved")
    }
    let target = scratch.appendingPathComponent("pages-\(tag).pdf")
    defer { try? FileManager.default.removeItem(at: target) }
    guard (try? result.write(to: target)) != nil else { return ["cannot write scratch copy"] }
    // LUMA_PAGES_KEEP=<dir>: keeps a copy of each result there, for looking into a failure by hand.
    if let keep = ProcessInfo.processInfo.environment["LUMA_PAGES_KEEP"] {
        try? result.write(to: URL(fileURLWithPath: keep).appendingPathComponent("pages-\(tag).pdf"))
    }

    /// Where each page of the original went: its new place, or nil when removed.
    var newPlace: [Int: Int] = [:]
    for (k, origin) in origins.enumerated() where origin.doc == 0 { newPlace[origin.page] = k }

    // System engine.
    guard let after = PDFDocument(url: target) else { return problems + ["system engine cannot open the result"] }
    if after.pageCount != origins.count { return problems + ["system engine: \(after.pageCount) pages, expected \(origins.count)"] }
    var textChanged = 0, geometryChanged = 0, lostAnnotations = 0, gainedAnnotations = 0, pictureChanged = 0, unrendered = 0
    // Copies opened only for drawing upright, so that turning their pages does not touch the readings.
    let drawingCopies = docs.map { PDFDocument(url: $0.url) }
    let resultCopy = PDFDocument(url: target)
    for (k, origin) in origins.enumerated() {
        guard let b = after.page(at: k), let a = docs[origin.doc].pdf.page(at: origin.page) else { unrendered += 1; continue }
        let wasTurned = a.rotation != origin.rotation
        if a.string != b.string {
            var readings = Set([a.string ?? ""])
            for _ in 0..<3 { readings.insert(PDFDocument(url: docs[origin.doc].url)?.page(at: origin.page)?.string ?? "") }
            if readings.count > 1 {
                unstableReadings += 1
            } else if wasTurned && sortedCharacters(a.string ?? "") == sortedCharacters(b.string ?? "") {
                orderOnlyText += 1
            } else if (origin.doc != 0 || structureLeftBehind) && (docs[origin.doc].mupdfPages[origin.page]["structured"] as? Bool) == true
                        && sortedCharacters(a.string ?? "") == sortedCharacters(b.string ?? "") {
                // The system engine too orders a page's text by the structure information left behind.
                structureOrderOnly += 1
            } else if origin.doc != 0 && docs[origin.doc].leavesAnnotationsBehind[origin.page]
                        && sortedCharacters(a.string ?? "") == sortedCharacters(b.string ?? "") {
                // The system engine reads a page's text in another order once its links and form fields
                // are gone (checked by removing them from a copy of the original: the same order results).
                annotationsOrderOnly += 1
            } else {
                textChanged += 1
                if debugging {
                    let x = sortedCharacters(a.string ?? ""), y = sortedCharacters(b.string ?? "")
                    print("  debug system text page \(k + 1) (from doc \(origin.doc) page \(origin.page + 1), turn \(a.rotation) → \(origin.rotation)): \(x.count) → \(y.count) characters; only before: \(String(Set(x).subtracting(Set(y))).prefix(20)); only after: \(String(Set(y).subtracting(Set(x))).prefix(20))")
                }
            }
        }
        func near(_ x: CGRect, _ y: CGRect) -> Bool {
            abs(x.minX - y.minX) < 0.001 && abs(x.minY - y.minY) < 0.001 && abs(x.maxX - y.maxX) < 0.001 && abs(x.maxY - y.maxY) < 0.001
        }
        if !near(a.bounds(for: .mediaBox), b.bounds(for: .mediaBox)) || !near(a.bounds(for: .cropBox), b.bounds(for: .cropBox)) || b.rotation != origin.rotation {
            geometryChanged += 1
            if debugging { print("  debug geometry page \(k + 1): media \(a.bounds(for: .mediaBox)) → \(b.bounds(for: .mediaBox)), crop \(a.bounds(for: .cropBox)) → \(b.bounds(for: .cropBox)), turn \(b.rotation) wanted \(origin.rotation)") }
        }
        var remaining = b.annotations.map(describe)
        let old = a.annotations.map(describe)
        if origin.doc == 0 {
            for item in old {
                if let found = remaining.firstIndex(of: item) { remaining.remove(at: found) } else { lostAnnotations += 1 }
            }
            gainedAnnotations += remaining.count
        } else {
            // An inserted page keeps every annotation except links, form fields and pop-ups, which may stay behind.
            var pool = old
            for item in remaining {
                if let found = pool.firstIndex(of: item) { pool.remove(at: found) } else { gainedAnnotations += 1 }
            }
            lostAnnotations += pool.filter { !["Link", "Widget", "Popup"].contains($0.split(separator: "|").first.map(String.init) ?? "") }.count
        }
        // An inserted page that left annotations behind is compared without any drawn; its annotations
        // were compared above.
        let hiding = origin.doc != 0 && docs[origin.doc].leavesAnnotationsBehind[origin.page]
        guard let before = autoreleasepool(invoking: { renderUpright(drawingCopies[origin.doc], page: origin.page, hidingAnnotations: hiding) }),
              let now = autoreleasepool(invoking: { renderUpright(resultCopy, page: k, hidingAnnotations: hiding) }) else {
            unrendered += 1
            continue
        }
        let changed = difference(before, now)
        if changed.count != 0 {
            pictureChanged += 1
            if debugging { print("  debug system picture page \(k + 1) (from doc \(origin.doc) page \(origin.page + 1)): \(changed.count) pixels in \(changed.bounds), annotations \(a.annotations.map { $0.type ?? "?" })") }
        }
    }
    if unrendered > 0 { problems.append("system engine: \(unrendered) pages could not be read or rendered, so they were not compared") }
    if textChanged > 0 { problems.append("system engine: text differs on \(textChanged) pages") }
    if geometryChanged > 0 { problems.append("system engine: size or turn differs on \(geometryChanged) pages") }
    if lostAnnotations > 0 { problems.append("system engine: \(lostAnnotations) annotations lost") }
    if gainedAnnotations > 0 { problems.append("system engine: \(gainedAnnotations) annotations appeared") }
    if pictureChanged > 0 { problems.append("system engine: \(pictureChanged) pages draw differently when upright") }

    // poppler.
    guard let poppler = popplerReadings(target, scratch: scratch) else { return problems + ["poppler could not read the result"] }
    if poppler.text.count != origins.count || poppler.sizes.count != origins.count || poppler.pictures.count != origins.count {
        return problems + ["poppler: page count differs (\(poppler.text.count) texts, \(poppler.sizes.count) sizes, \(poppler.pictures.count) pictures)"]
    }
    let known = docs.reduce(into: Set<String>()) { $0.formUnion($1.messages) }
    let newMessages = poppler.messages.subtracting(known)
    if !newMessages.isEmpty { problems.append("poppler: new messages: \(newMessages.prefix(3).joined(separator: " / "))") }
    // Turned pages are compared drawn as they were turned before: a copy of the result with each
    // page given its old turn back (by the writer, which only rewrites /Rotate) must render exactly
    // like the pages it came from. Comparing turned renderings directly does not work: glyphs are
    // rasterised differently in another orientation.
    var popplerText = 0, popplerGeometry = 0, popplerPictures = 0
    let back = origins.enumerated().map { PageSlot(.original($0.offset), rotation: docs[$0.element.doc].rotations[$0.element.page]) }
    let uprightFile = scratch.appendingPathComponent("pages-\(tag)-back.pdf")
    defer { try? FileManager.default.removeItem(at: uprightFile) }
    var uprightPictures: [Picture] = []
    var uprightWithoutAnnotations: [Picture] = []
    if let upright = try? PDFPageWriter.applying(back, to: result), (try? upright.write(to: uprightFile)) != nil {
        let rendered = run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", uprightFile.path], in: scratch)
        uprightPictures = splitPGM(rendered.output)
        if origins.contains(where: { $0.doc != 0 && docs[$0.doc].leavesAnnotationsBehind[$0.page] }) {
            uprightWithoutAnnotations = splitPGM(run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", "-hide-annotations", uprightFile.path], in: scratch).output)
        }
    }
    if uprightPictures.count != origins.count { problems.append("poppler: could not render the result with its old turns back") }
    for (k, origin) in origins.enumerated() {
        let doc = docs[origin.doc]
        let delta = ((origin.rotation - doc.rotations[origin.page]) % 360 + 360) % 360
        if poppler.text[k] != doc.text[origin.page] {
            if delta != 0 && sortedCharacters(poppler.text[k]) == sortedCharacters(doc.text[origin.page]) {
                orderOnlyText += 1
            } else if delta != 0 && sortedCharacters(poppler.text[k]) == sortedCharacters(popplerTextTurnedByMuPDF(doc.url, page: origin.page, rotation: origin.rotation, scratch: scratch, helper: helper) ?? "") {
                // poppler reads the page differently once turned, whoever turns it.
                turnedReadingsMatchingMuPDF += 1
            } else {
                popplerText += 1
                if debugging {
                    let a = sortedCharacters(doc.text[origin.page]), b = sortedCharacters(poppler.text[k])
                    print("  debug poppler text page \(k + 1) (from doc \(origin.doc) page \(origin.page + 1), turned \(delta)): \(a.count) → \(b.count) characters; only before: \(String(Set(a).subtracting(Set(b))).prefix(20)); only after: \(String(Set(b).subtracting(Set(a))).prefix(20))")
                }
            }
        }
        if poppler.sizes[k] != doc.sizes[origin.page] || poppler.rotations[k] != origin.rotation { popplerGeometry += 1 }
        if delta != 0 { turnedRenderingsCompared += 1 }
        // The document's colour profile for output stays with it: an inserted page is drawn, by poppler,
        // as its own document draws it without that profile.
        let intentLeftBehind = origin.doc != 0 && doc.hasOutputIntents && !docs[0].hasOutputIntents
        if intentLeftBehind { intentPagesCompared += 1 }
        let sourcePictures = intentLeftBehind ? doc.picturesWithoutOutputIntents(scratch: scratch, helper: helper).pictures : doc.pictures
        if origin.doc != 0 && doc.leavesAnnotationsBehind[origin.page] {
            let hidden = intentLeftBehind ? doc.picturesWithoutOutputIntents(scratch: scratch, helper: helper).hidden : doc.picturesWithoutAnnotations(scratch: scratch)
            if hidden.count != doc.pictures.count || uprightWithoutAnnotations.count != origins.count
                || difference(hidden[origin.page], uprightWithoutAnnotations[k]).count != 0 {
                popplerPictures += 1
                if debugging { print("  debug poppler hidden picture page \(k + 1): \(hidden.count)/\(doc.pictures.count) \(uprightWithoutAnnotations.count)/\(origins.count) \(hidden.indices.contains(origin.page) && uprightWithoutAnnotations.indices.contains(k) ? difference(hidden[origin.page], uprightWithoutAnnotations[k]).count : -1)") }
            }
            continue
        }
        guard sourcePictures.count == doc.pictures.count else {
            popplerPictures += 1
            continue
        }
        if delta == 0 && difference(sourcePictures[origin.page], poppler.pictures[k]).count != 0 { popplerPictures += 1 }
        if uprightPictures.count == origins.count && difference(sourcePictures[origin.page], uprightPictures[k]).count != 0 {
            popplerPictures += 1
            if debugging { print("  debug poppler picture page \(k + 1) (from doc \(origin.doc) page \(origin.page + 1), turned \(delta)): \(difference(sourcePictures[origin.page], uprightPictures[k]))") }
        }
    }
    if popplerText > 0 { problems.append("poppler: text differs on \(popplerText) pages") }
    if popplerGeometry > 0 { problems.append("poppler: size or turn differs on \(popplerGeometry) pages") }
    if popplerPictures > 0 { problems.append("poppler: \(popplerPictures) pages render differently") }

    // MuPDF.
    let report = run(python, ["-I", helper, target.path], in: scratch)
    guard let parsed = try? JSONSerialization.jsonObject(with: report.output) as? [[String: Any]], parsed.count == 1 else {
        return problems + ["MuPDF helper could not be run — third reader did not check this file"]
    }
    let now = parsed[0]
    guard (now["ok"] as? Bool) == true else { return problems + ["MuPDF: cannot open (\(now["error"] as? String ?? "?"))"] }
    let original = docs[0].mupdf
    if (original["repaired"] as? Bool) != (now["repaired"] as? Bool) { problems.append("MuPDF: needs repair \(original["repaired"] ?? "?") → \(now["repaired"] ?? "?")") }
    let knownWarnings = docs.reduce(into: Set<String>()) { $0.formUnion(($1.mupdf["warnings"] as? String ?? "").split(separator: "\n").map(String.init)) }
    // "… repeated 2 times…" only counts a warning seen again, as it is when a page is inserted twice.
    let newWarnings = Set((now["warnings"] as? String ?? "").split(separator: "\n").map(String.init))
        .subtracting(knownWarnings).filter { !($0.hasPrefix("... repeated ") && $0.hasSuffix(" times...")) }
    if !newWarnings.isEmpty { problems.append("MuPDF: new warnings: \(newWarnings.prefix(3).joined(separator: " / "))") }
    let pagesNow = now["pages"] as? [[String: Any]] ?? []
    guard pagesNow.count == origins.count else { return problems + ["MuPDF: \(pagesNow.count) pages, expected \(origins.count)"] }
    var mText = 0, mGeometry = 0, mAnnotations = 0, mLinks = 0, mControls = 0
    for (k, origin) in origins.enumerated() {
        let a = docs[origin.doc].mupdfPages[origin.page], b = pagesNow[k]
        let wasTurned = (a["rotation"] as? Int) != origin.rotation
        if (a["text"] as? String) != (b["text"] as? String) {
            if wasTurned && (a["chars"] as? String) == (b["chars"] as? String) {
                orderOnlyText += 1
            } else if (origin.doc != 0 || structureLeftBehind) && (a["structured"] as? Bool) == true && (a["chars"] as? String) == (b["chars"] as? String) {
                // MuPDF orders a page's text by the document's structure information, which an
                // inserted page leaves behind by design: the same characters, read in another order.
                structureOrderOnly += 1
            } else {
                mText += 1
                if debugging { print("  debug MuPDF text page \(k + 1) (from doc \(origin.doc) page \(origin.page + 1), turn \(a["rotation"] ?? "?") → \(origin.rotation)), same characters: \((a["chars"] as? String) == (b["chars"] as? String))") }
            }
        }
        if numbers(a["mediabox"]) != numbers(b["mediabox"]) || (b["rotation"] as? Int) != origin.rotation { mGeometry += 1 }
        let oldAnnotations = (a["annotations"] as? [[Any]] ?? []).map(stable)
        var newAnnotations = (b["annotations"] as? [[Any]] ?? []).map(stable)
        if origin.doc == 0 && !wasTurned {
            if oldAnnotations.sorted() != newAnnotations.sorted() { mAnnotations += 1 }
        } else {
            // MuPDF gives rectangles as shown, so on a turned page only kinds and notes are compared.
            func kindAndNote(_ s: String) -> String { let p = s.split(separator: "|", omittingEmptySubsequences: false); return "\(p.first ?? "")|\(p.last ?? "")" }
            var pool = oldAnnotations.map(kindAndNote)
            newAnnotations = newAnnotations.map(kindAndNote)
            var extra = 0
            for item in newAnnotations { if let f = pool.firstIndex(of: item) { pool.remove(at: f) } else { extra += 1 } }
            let lost = origin.doc == 0 ? pool.count : pool.filter { !["Link", "Widget", "Popup"].contains(String($0.split(separator: "|").first ?? "")) }.count
            if extra > 0 || lost > 0 { mAnnotations += 1 }
        }
        // Links: those within the document lead to where their page is now; to a removed page, nowhere.
        func linkKey(_ item: [Any], turned: Bool) -> String? {
            guard item.count == 2, let target = item[1] as? String else { return nil }
            let place = turned ? "" : numbers(item[0])
            return "\(place)|\(target)"
        }
        var expected: [String] = []
        var resolvedAway = 0
        for item in a["links"] as? [[Any]] ?? [] {
            guard item.count == 2, var target = item[1] as? String else { continue }
            // A link within the inserted document (to a page, or to a name there) stays behind.
            if origin.doc != 0 && (target.hasPrefix("page:") || target == "kind:4") { continue }
            if target.hasPrefix("page:") {
                guard let page = Int(target.dropFirst(5)) else { continue }
                if page >= 0 {
                    // A link to a removed page leads nowhere now.
                    guard let moved = newPlace[page] else { resolvedAway += 1; continue }
                    target = "page:\(moved)"
                }
            }
            if let key = linkKey([item[0], target], turned: wasTurned) { expected.append(key) }
        }
        let found = (b["links"] as? [[Any]] ?? []).compactMap { linkKey($0, turned: wasTurned) }.filter { !$0.hasSuffix("|kind:0") }
        var missing = expected.filter { !$0.hasSuffix("|kind:0") }
        var extra: [String] = []
        for item in found { if let f = missing.firstIndex(of: item) { missing.remove(at: f) } else { extra.append(item) } }
        // A link to a name MuPDF cannot look up (kind 4 with no page) may lead to a removed page all the
        // same: such links may go, as many as the system engine sees leading to removed pages.
        let leadingAway = origin.doc == 0
            ? docs[0].linkTargets[origin.page].filter { $0.map { newPlace[$0] == nil } ?? false }.count - resolvedAway : 0
        let unexplained = !extra.isEmpty || missing.contains { !$0.hasSuffix("|kind:4") } || missing.count > leadingAway
        if unexplained {
            mLinks += 1
            if debugging { print("  debug links page \(k + 1): expected \(expected.sorted().prefix(6)) found \(found.sorted().prefix(6))") }
        }
        let controlsNow = (b["controls"] as? [[Any]] ?? []).count
        if origin.doc == 0 {
            if !wasTurned && (a["controls"] as? [[Any]] ?? []).map(stable) != (b["controls"] as? [[Any]] ?? []).map(stable) { mControls += 1 }
            if wasTurned && (a["controls"] as? [[Any]] ?? []).count != controlsNow { mControls += 1 }
        } else if controlsNow != 0 {
            mControls += 1
        }
    }
    if mText > 0 { problems.append("MuPDF: text differs on \(mText) pages") }
    if mGeometry > 0 { problems.append("MuPDF: size or turn differs on \(mGeometry) pages") }
    if mAnnotations > 0 { problems.append("MuPDF: annotations differ on \(mAnnotations) pages") }
    if mLinks > 0 { problems.append("MuPDF: links differ on \(mLinks) pages") }
    if mControls > 0 { problems.append("MuPDF: form controls differ on \(mControls) pages") }
    // The outline: every entry stays, leading to where its page went, or nowhere if it was removed.
    let tocBefore = original["toc"] as? [[Any]] ?? []
    let tocNow = now["toc"] as? [[Any]] ?? []
    // An entry that leads nowhere (the system engine sees no page), MuPDF shows on some page of its own
    // choosing, which page edits do not change.
    let nowhere = docs[0].outlineLeadsNowhere.count == tocBefore.count ? docs[0].outlineLeadsNowhere : []
    let expectedToc = tocBefore.enumerated().map { place, entry -> String in
        let page = (entry.count > 2 ? entry[2] as? Int : nil) ?? -1
        let moved = nowhere.indices.contains(place) && nowhere[place] ? page : page >= 1 ? newPlace[page - 1].map { $0 + 1 } ?? -1 : page
        return "\(entry.first ?? "")|\(entry.count > 1 ? entry[1] : "")|\(moved)"
    }
    let foundToc = tocNow.map { "\($0.first ?? "")|\($0.count > 1 ? $0[1] : "")|\($0.count > 2 ? $0[2] : "")" }
    if expectedToc != foundToc {
        let firstDifference = zip(expectedToc, foundToc).first { $0 != $1 }.map { "\($0.0) → \($0.1)" } ?? "\(expectedToc.count) → \(foundToc.count) entries"
        problems.append("MuPDF: outline differs (\(firstDifference))")
    }
    return problems
}

func runPageEdits(scratch: URL, helper: String, paths: [String]) -> Int32 {
    var passed = 0
    var turnedAway: [String: [String]] = [:]
    var writerFailures: [String] = []
    var checkFailures: [String] = []
    var notExamined: [String] = []
    var coverage: [String: Int] = [:]
    func cover(_ label: String, _ condition: Bool) { if condition { coverage[label, default: 0] += 1 } }

    // LUMA_PAGES_FIRST_ONLY: check only the first file (the second is still what is inserted from).
    let checked = ProcessInfo.processInfo.environment["LUMA_PAGES_FIRST_ONLY"] != nil ? Array(paths.prefix(1)) : paths
    for (index, path) in checked.enumerated() {
        autoreleasepool {
            let url = URL(fileURLWithPath: path)
            let label = String(url.lastPathComponent.prefix(46))
            guard let original = try? Data(contentsOf: url), let readings = Readings(url, scratch: scratch, helper: helper) else {
                notExamined.append(label)
                return
            }
            // The file to insert from: the next one in the list that can be copied from.
            var sourceReadings: Readings?
            var sourceData = Data()
            for step in 1..<max(2, paths.count) {
                let candidate = URL(fileURLWithPath: paths[(index + step) % paths.count])
                guard let data = try? Data(contentsOf: candidate), PDFPageWriter.reasonPagesCannotBeInserted(from: data) == nil,
                      let r = Readings(candidate, scratch: scratch, helper: helper) else { continue }
                sourceReadings = r
                sourceData = data
                break
            }
            guard let source = sourceReadings else { notExamined.append("\(label) (no file to insert from)"); return }
            let docs = [readings, source]

            let facts: PDFFileFacts
            let startRotations: [Int]
            do {
                facts = try PDFAppendWriter.facts(of: original)
                startRotations = try PDFPageWriter.rotations(of: original)
            } catch let error as PDFAppendError {
                turnedAway[error.description, default: []].append(label)
                return
            } catch {
                writerFailures.append("\(label): \(error)")
                return
            }
            let n = startRotations.count
            guard n == readings.pdf.pageCount else {
                checkFailures.append("\(label): writer counts \(n) pages, system engine \(readings.pdf.pageCount)")
                return
            }
            if startRotations != (0..<n).map({ readings.pdf.page(at: $0)?.rotation ?? -1 }) {
                checkFailures.append("\(label): writer and system engine disagree about how pages are turned")
                return
            }
            cover("compressed index", facts.compressedIndex)
            cover("old-style index", !facts.compressedIndex)
            cover("more than one index section", facts.indexSections > 1)
            cover("linearized", facts.linearized)
            cover("pages stored inside object packs", facts.pagesInsideObjectPacks > 0)
            cover("pages listed in lower branches of the page tree", facts.pagesBelowBranches > 0)
            cover("pages taking resources, size or turn from a lower branch", facts.pagesInheritingFromBranches > 0)
            cover("already carries annotations", (0..<n).contains { !(readings.pdf.page(at: $0)?.annotations.isEmpty ?? true) })
            cover("has an outline", !((readings.mupdf["toc"] as? [Any])?.isEmpty ?? true))
            cover("has a turned page", startRotations.contains { $0 != 0 })

            func turn(_ r: Int, _ by: Int) -> Int { (r + by) % 360 }
            var problems: [String] = []

            // 1. Turns.
            var turns = startRotations
            turns[0] = turn(turns[0], 90)
            if n >= 3 { turns[n / 2] = turn(turns[n / 2], 180) }
            if n >= 2 { turns[n - 1] = turn(turns[n - 1], 270) }
            let firstOrigins = (0..<n).map { Origin(doc: 0, page: $0, rotation: turns[$0]) }
            let first: Data
            do {
                first = try PDFPageWriter.applying(firstOrigins.map { PageSlot(.original($0.page), rotation: $0.rotation) }, to: original)
            } catch let error as PDFAppendError {
                if case .selfCheckFailed = error { writerFailures.append("\(label): turning — \(error)") } else { turnedAway[error.description, default: []].append(label) }
                return
            } catch {
                writerFailures.append("\(label): turning — \(error)")
                return
            }
            problems += checkPageEdit(result: first, previous: original, origins: firstOrigins, docs: docs, scratch: scratch,
                                      helper: helper, tag: "\(index)a").map { "after turning — \($0)" }

            // 2. Remove the middle page, swap the first and the last.
            var order = Array(0..<n)
            if n >= 3 { order.remove(at: n / 2) }
            if order.count >= 2 { order.swapAt(0, order.count - 1) }
            let secondOrigins = order.map { firstOrigins[$0] }
            let second: Data
            do {
                second = try PDFPageWriter.applying(order.map { PageSlot(.original($0), rotation: firstOrigins[$0].rotation) }, to: first)
            } catch {
                writerFailures.append("\(label): removing and reordering on top of its own save failed — \(error)")
                return
            }
            problems += checkPageEdit(result: second, previous: first, origins: secondOrigins, docs: docs, scratch: scratch,
                                      helper: helper, tag: "\(index)b").map { "after removing and reordering — \($0)" }

            // 3. Insert a page of the next file after the first page, and append that file.
            let sourceCount = source.pdf.pageCount
            let merged = sourceCount <= 40 ? Array(0..<sourceCount) : Array(0..<5)
            var thirdSlots = (0..<secondOrigins.count).map { PageSlot(.original($0), rotation: secondOrigins[$0].rotation) }
            var thirdOrigins = secondOrigins
            thirdSlots.insert(PageSlot(.inserted(source: 0, page: 0), rotation: turn(source.rotations[0], 90)), at: 1)
            thirdOrigins.insert(Origin(doc: 1, page: 0, rotation: turn(source.rotations[0], 90)), at: 1)
            for page in merged {
                thirdSlots.append(PageSlot(.inserted(source: 0, page: page), rotation: source.rotations[page]))
                thirdOrigins.append(Origin(doc: 1, page: page, rotation: source.rotations[page]))
            }
            let third: Data
            do {
                third = try PDFPageWriter.applying(thirdSlots, sources: [sourceData], to: second)
            } catch let error as PDFAppendError {
                if case .selfCheckFailed = error { writerFailures.append("\(label): inserting — \(error)") } else {
                    turnedAway["inserting from \(source.url.lastPathComponent.prefix(30)): \(error.description)", default: []].append(label)
                }
                if problems.isEmpty { passed += 1 } else { checkFailures.append("\(label): \(problems.prefix(12).joined(separator: "; "))") }
                return
            } catch {
                writerFailures.append("\(label): inserting — \(error)")
                return
            }
            problems += checkPageEdit(result: third, previous: second, origins: thirdOrigins, docs: docs, scratch: scratch,
                                      helper: helper, tag: "\(index)c").map { "after inserting — \($0)" }
            print("\(index + 1)/\(paths.count) \(problems.isEmpty ? "ok" : "PROBLEMS") \(label)\(problems.isEmpty ? "" : "\n    " + problems.joined(separator: "\n    "))")
            fflush(stdout)
            if problems.isEmpty { passed += 1 } else { checkFailures.append("\(label): \(problems.prefix(12).joined(separator: "; "))") }
        }
    }

    print("files given: \(paths.count)")
    print("passed every check: \(passed)")
    print("turned away untouched: \(turnedAway.values.reduce(0) { $0 + $1.count })")
    for (reason, files) in turnedAway.sorted(by: { $0.value.count > $1.value.count }) {
        print("  \(files.count) × \(reason)")
        files.prefix(8).forEach { print("      \($0)") }
    }
    print("could not be examined at all: \(notExamined.count)")
    notExamined.prefix(10).forEach { print("  ! \($0)") }
    print("WRITER FAILURES (its own output was bad): \(writerFailures.count)")
    writerFailures.prefix(20).forEach { print("  ! \($0)") }
    print("handled but failed a check: \(checkFailures.count)")
    checkFailures.prefix(40).forEach { print("  ! \($0)") }
    print("page readings skipped because the system engine reads the original inconsistently: \(unstableReadings)")
    print("turned pages whose text came out in another order but with the same characters: \(orderOnlyText)")
    print("turned pages compared by rendering with their old turn given back: \(turnedRenderingsCompared)")
    print("turned pages whose poppler text differs, but exactly as when MuPDF turns the same page: \(turnedReadingsMatchingMuPDF)")
    print("inserted pages whose system-engine text has the same characters in another order, their links or form fields left behind: \(annotationsOrderOnly)")
    print("inserted pages drawn by poppler without their document's colour profile for output: \(intentPagesCompared)")
    print("inserted pages whose text (system engine or MuPDF) has the same characters in another order, their structure information left behind: \(structureOrderOnly)")
    print("kinds of file among those handled:")
    for (label, count) in coverage.sorted(by: { $0.value > $1.value }) { print("  \(count) × \(label)") }
    if passed == 0 { print("NOTHING PASSED: no file was actually written and checked.") }
    return writerFailures.isEmpty && checkFailures.isEmpty && notExamined.isEmpty && passed > 0 ? 0 : 1
}

// `luma-corpus-check --slim <scratch-dir> <mupdf-pages.py> <file> [more files...]`
//
// Makes slim copies and checks them with the three readers, page by page, as page edits are
// checked: a slim copy of the file as it is, and one of the file after removing its middle page
// and swapping its first and last (saved by appending first). The copies are new files, so there is
// no prefix to keep; everything else must read the same. Pages lose only their structure information.
func runSlimCopies(scratch: URL, helper: String, paths: [String]) -> Int32 {
    var passed = 0
    var turnedAway: [String: [String]] = [:]
    var writerFailures: [String] = []
    var checkFailures: [String] = []
    var notExamined: [String] = []
    var sizes: [(original: Int, appended: Int, copy: Int)] = []
    for (index, path) in paths.enumerated() {
        autoreleasepool {
            let url = URL(fileURLWithPath: path)
            let label = String(url.lastPathComponent.prefix(46))
            guard let original = try? Data(contentsOf: url), let readings = Readings(url, scratch: scratch, helper: helper) else {
                notExamined.append(label)
                return
            }
            let rotations: [Int]
            do { rotations = try PDFPageWriter.rotations(of: original) } catch {
                turnedAway["\(error)", default: []].append(label)
                return
            }
            let n = rotations.count
            var problems: [String] = []
            let whole: Data
            do {
                whole = try PDFSlimCopy.making(from: original)
            } catch let error as PDFAppendError {
                if case .selfCheckFailed = error { writerFailures.append("\(label): \(error)") } else { turnedAway[error.description, default: []].append(label) }
                return
            } catch {
                writerFailures.append("\(label): \(error)")
                return
            }
            problems += checkPageEdit(result: whole, previous: nil, origins: (0..<n).map { Origin(doc: 0, page: $0, rotation: rotations[$0]) },
                                      docs: [readings], scratch: scratch, helper: helper, tag: "\(index)w", structureLeftBehind: true)
                .map { "copy of the file — \($0)" }
            var order = Array(0..<n)
            if n >= 3 { order.remove(at: n / 2) }
            if order.count >= 2 { order.swapAt(0, order.count - 1) }
            do {
                let appended = try PDFPageWriter.applying(order.map { PageSlot(.original($0), rotation: rotations[$0]) }, to: original)
                let copy = try PDFSlimCopy.making(from: appended)
                sizes.append((original.count, appended.count, copy.count))
                problems += checkPageEdit(result: copy, previous: nil, origins: order.map { Origin(doc: 0, page: $0, rotation: rotations[$0]) },
                                          docs: [readings], scratch: scratch, helper: helper, tag: "\(index)r", structureLeftBehind: true)
                    .map { "copy after removing and reordering — \($0)" }
            } catch {
                writerFailures.append("\(label): copy after removing and reordering — \(error)")
                return
            }
            print("\(index + 1)/\(paths.count) \(problems.isEmpty ? "ok" : "PROBLEMS") \(label)\(problems.isEmpty ? "" : "\n    " + problems.joined(separator: "\n    "))")
            fflush(stdout)
            if problems.isEmpty { passed += 1 } else { checkFailures.append("\(label): \(problems.prefix(12).joined(separator: "; "))") }
        }
    }
    print("files given: \(paths.count)")
    print("passed every check: \(passed)")
    print("turned away untouched: \(turnedAway.values.reduce(0) { $0 + $1.count })")
    for (reason, files) in turnedAway.sorted(by: { $0.value.count > $1.value.count }) {
        print("  \(files.count) × \(reason)")
        files.prefix(8).forEach { print("      \($0)") }
    }
    print("could not be examined at all: \(notExamined.count)")
    notExamined.prefix(10).forEach { print("  ! \($0)") }
    print("WRITER FAILURES (its own output was bad): \(writerFailures.count)")
    writerFailures.prefix(20).forEach { print("  ! \($0)") }
    print("handled but failed a check: \(checkFailures.count)")
    checkFailures.prefix(40).forEach { print("  ! \($0)") }
    print("page readings skipped because the system engine reads the original inconsistently: \(unstableReadings)")
    print("pages whose text has the same characters in another order, their structure information left behind: \(structureOrderOnly)")
    let shares = sizes.map { Double($0.copy) / Double(max(1, $0.appended)) }.sorted()
    if !shares.isEmpty {
        print(String(format: "copy after removing one page, as a share of the appended file: median %.2f, smallest %.2f, largest %.2f",
                     shares[shares.count / 2], shares.first!, shares.last!))
    }
    if passed == 0 { print("NOTHING PASSED: no file was actually written and checked.") }
    return writerFailures.isEmpty && checkFailures.isEmpty && notExamined.isEmpty && passed > 0 ? 0 : 1
}
