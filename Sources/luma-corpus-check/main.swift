import AppKit
import Foundation
import LumaCore
import PDFKit

// Runs the append writer over real PDFs and checks every result with three independent readers.
//
// For each file it saves three times — first one highlight on the first page; then, on top of that,
// highlights on the middle and last pages in a single save; then, on top of that, the first
// highlight given a new colour and note and the middle one deleted — and checks every result in full:
//   · the previous bytes are an exact prefix of the new file;
//   · system engine (PDFKit): same page count, text, page size and rotation; every annotation that
//     was there is still there; the new highlights are where they were put; pages without a new
//     highlight render pixel-for-pixel the same, and pages with one differ only where it is;
//   · poppler: same text, same messages, same page sizes, same rendering by the same rule;
//   · MuPDF: same text, page sizes, annotations, links and form controls, the new highlights in
//     place, same warnings, and no newly needed repair.
// Originals are only read. Everything written goes to the scratch directory and is deleted.
// Exits with status 1 if any file was written badly, failed a check, or could not be examined,
// and also if not a single file passed.
//
// usage: luma-corpus-check <scratch-dir> <mupdf-facts.py> <file> [more files...]
//        luma-corpus-check --triage <file> [more files...]
//        luma-corpus-check --write <input.pdf> <output.pdf> [page-number ...]
//        luma-corpus-check --pages <scratch-dir> <mupdf-pages.py> <file> [more files...]   (page edits; see PageEdits.swift)
//        luma-corpus-check --slim <scratch-dir> <mupdf-pages.py> <file> [more files...]   (slim copies; see PageEdits.swift)
//        luma-corpus-check --open-check <file> [more files...]   (the open-time check, read both ways, compared)
//        luma-corpus-check --open-check-memory old|new <file>   (that check's memory, in a fresh process)

let popplerDirectory = "/opt/homebrew/bin"
// A Python with pymupdf installed: LUMA_PYTHON when set, else the first of the usual places that
// has one (an Anaconda in the home folder or in /opt, then Homebrew's and the system's).
let python: String = {
    if let chosen = ProcessInfo.processInfo.environment["LUMA_PYTHON"] { return chosen }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [home + "/anaconda3/bin/python3", home + "/miniconda3/bin/python3", "/opt/anaconda3/bin/python3",
                      "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    func hasPyMuPDF(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: path)
        probe.arguments = ["-c", "import fitz"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }
    return candidates.first(where: hasPyMuPDF) ?? "/usr/bin/python3"
}()

struct ToolResult {
    var launched = false
    var status: Int32 = -1
    var output = Data()
    var messages = ""
}

func run(_ tool: String, _ arguments: [String], in scratch: URL) -> ToolResult {
    var result = ToolResult()
    guard FileManager.default.isExecutableFile(atPath: tool) else { return result }
    let messagesFile = scratch.appendingPathComponent("messages-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: messagesFile.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: messagesFile) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = try? FileHandle(forWritingTo: messagesFile)
    do { try process.run() } catch { return result }
    result.launched = true
    result.output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    result.status = process.terminationStatus
    result.messages = (try? String(contentsOf: messagesFile, encoding: .utf8)) ?? ""
    return result
}

/// Pages skipped by the system-engine text comparison because the engine reads the original inconsistently.
var unstablePages = 0
/// Marked pages where only the amount of change was checked, not its place, because the page is rotated.
var placeUncheckedPages = 0

struct Mark {
    let page: Int
    let rect: CGRect
    let note: String
    var kind: MarkupAddition.Kind = .highlight

    /// The rectangle the annotation is written with: the line's own for a highlight, the drawing's
    /// (a little larger, by the line's thickness) for an underline or strikethrough.
    var written: CGRect {
        kind == .highlight ? rect : MarkupAppearance.drawing(kind: kind, quads: [MarkupQuad(rect)], red: 1, green: 0.92, blue: 0.23).bounds
    }
}

struct Picture {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let bytesPerPixel: Int
}

func render(_ page: PDFPage, scale: CGFloat) -> Picture? {
    let box = page.bounds(for: .mediaBox)
    let width = Int(box.width * scale), height = Int(box.height * scale)
    guard width > 0, height > 0, width < 4000, height < 4000 else { return nil }
    var buffer = [UInt8](repeating: 255, count: width * height * 4)
    let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return true
    }
    return drawn ? Picture(pixels: buffer, width: width, height: height, bytesPerPixel: 4) : nil
}

/// How many pixels differ between two pictures, and the box around them (rows counted from the top).
func difference(_ a: Picture, _ b: Picture) -> (count: Int, bounds: CGRect) {
    guard a.width == b.width, a.height == b.height, a.pixels.count == b.pixels.count else { return (Int.max, .infinite) }
    var count = 0
    var minX = a.width, minY = a.height, maxX = -1, maxY = -1
    let step = a.bytesPerPixel
    for y in 0..<a.height {
        for x in 0..<a.width {
            let i = (y * a.width + x) * step
            var same = true
            for k in 0..<step where a.pixels[i + k] != b.pixels[i + k] { same = false }
            if !same {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    return (count, maxX < 0 ? .null : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
}

/// Splits a stream of binary PGM images, as written by `pdftoppm -gray`, into one picture per page.
func splitPGM(_ data: Data) -> [Picture] {
    let bytes = [UInt8](data)
    var pages: [Picture] = []
    var i = 0
    func word() -> String {
        while i < bytes.count && (bytes[i] == 10 || bytes[i] == 32 || bytes[i] == 13 || bytes[i] == 9) { i += 1 }
        let start = i
        while i < bytes.count && !(bytes[i] == 10 || bytes[i] == 32 || bytes[i] == 13 || bytes[i] == 9) { i += 1 }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }
    while i < bytes.count {
        guard word() == "P5", let width = Int(word()), let height = Int(word()), Int(word()) != nil else { break }
        i += 1
        guard width > 0, height > 0, i + width * height <= bytes.count else { break }
        pages.append(Picture(pixels: Array(bytes[i..<(i + width * height)]), width: width, height: height, bytesPerPixel: 1))
        i += width * height
    }
    return pages
}

/// Checks the change on a page that received highlights: something must have changed, and — when the
/// page is upright, so that the place can be worked out — only inside the highlights' own boxes.
func checkMarkedPage(_ before: Picture, _ after: Picture, marks: [Mark], page: PDFPage, scale: CGFloat,
                     margin: CGFloat, reader: String, pageNumber: Int) -> [String] {
    let changed = difference(before, after)
    if changed.count == 0 { return ["\(reader): highlight on page \(pageNumber) is not visible"] }
    guard page.rotation == 0 else {
        placeUncheckedPages += 1
        let allowance = marks.reduce(400) { $0 + Int($1.rect.width * $1.rect.height * scale * scale * 4) }
        return changed.count > allowance ? ["\(reader): page \(pageNumber) changed more than its highlights explain (\(changed.count) pixels)"] : []
    }
    let media = page.bounds(for: .mediaBox)
    let allowed = marks.map { mark in
        CGRect(x: (mark.rect.minX - media.minX) * scale, y: (media.maxY - mark.rect.maxY) * scale,
               width: mark.rect.width * scale, height: mark.rect.height * scale).insetBy(dx: -margin, dy: -margin)
    }
    // Pixel by pixel: a change in the space between two highlights is as wrong as one anywhere else.
    var outside = 0
    let step = before.bytesPerPixel
    for y in 0..<before.height {
        for x in 0..<before.width {
            let i = (y * before.width + x) * step
            var same = true
            for k in 0..<step where before.pixels[i + k] != after.pixels[i + k] { same = false }
            if !same && !allowed.contains(where: { $0.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) }) { outside += 1 }
        }
    }
    return outside == 0 ? [] : ["\(reader): page \(pageNumber) changed outside its highlights (\(outside) pixels)"]
}

func describe(_ annotation: PDFAnnotation) -> String {
    let b = annotation.bounds
    return "\(annotation.type ?? "?")|\(Int(b.minX.rounded())),\(Int(b.minY.rounded())),\(Int(b.width.rounded())),\(Int(b.height.rounded()))|\(annotation.contents ?? "")"
}

/// A number or list of numbers from the MuPDF report, as plain text that compares reliably.
func numbers(_ value: Any?) -> String {
    if let list = value as? [Any] { return list.map { numbers($0) }.joined(separator: ",") }
    if let number = value as? NSNumber { return String(format: "%.2f", number.doubleValue) }
    return "?"
}

/// One item from the MuPDF report — [kind, rectangle, text] — as plain text that compares reliably.
func stable(_ item: [Any]) -> String {
    let kind = item.first as? String ?? "?"
    let text = item.count > 2 ? (item[2] as? String ?? "") : ""
    return "\(kind)|\(numbers(item.count > 1 ? item[1] : nil))|\(text)"
}

/// Compares one saved result with the file it was made from. Returns every problem found.
func check(originalURL: URL, original: Data, result: Data, marks: [Mark], scratch: URL, mupdfHelper: String, tag: String) -> [String] {
    var problems: [String] = []
    if !(result.count > original.count && result.prefix(original.count) == original) { problems.append("original bytes not preserved") }

    let target = scratch.appendingPathComponent("result-\(tag).pdf")
    defer { try? FileManager.default.removeItem(at: target) }
    guard (try? result.write(to: target)) != nil else { return ["cannot write scratch copy"] }
    let marksByPage = Dictionary(grouping: marks, by: \.page)

    // System engine.
    guard let before = PDFDocument(url: originalURL), let again = PDFDocument(url: originalURL), let after = PDFDocument(url: target) else {
        return problems + ["system engine cannot open the result"]
    }
    if before.pageCount != after.pageCount {
        problems.append("system engine: page count \(before.pageCount) → \(after.pageCount)")
    } else {
        var textChanged = 0, geometryChanged = 0, lostAnnotations = 0, pictureChanged = 0, unreadable = 0, unrendered = 0
        for index in 0..<before.pageCount {
            guard let a = before.page(at: index), let b = after.page(at: index) else {
                unreadable += 1
                continue
            }
            // On some figure-heavy pages the system engine returns different text each time it reads
            // the very same file. Such a page cannot be compared; the other two readers still check it.
            if a.string != again.page(at: index)?.string {
                unstablePages += 1
            } else if a.string != b.string {
                // Two matching reads do not prove the page is stable. Before blaming the save,
                // read the original a few more times and see whether it agrees with itself.
                var readings = Set([a.string ?? ""])
                for _ in 0..<5 { readings.insert(PDFDocument(url: originalURL)?.page(at: index)?.string ?? "") }
                if readings.count > 1 { unstablePages += 1 } else { textChanged += 1 }
            }
            if a.bounds(for: .mediaBox) != b.bounds(for: .mediaBox) || a.bounds(for: .cropBox) != b.bounds(for: .cropBox) || a.rotation != b.rotation {
                geometryChanged += 1
            }
            var remaining = b.annotations.map(describe)
            for old in a.annotations.map(describe) {
                if let found = remaining.firstIndex(of: old) { remaining.remove(at: found) } else { lostAnnotations += 1 }
            }
            let expected = marksByPage[index] ?? []
            if remaining.count != expected.count { problems.append("system engine: page \(index + 1) gained \(remaining.count) annotations, expected \(expected.count)") }
            for mark in expected {
                let placed = b.annotations.contains {
                    $0.type == mark.kind.rawValue && $0.contents == mark.note
                        && abs($0.bounds.minX - mark.written.minX) < 0.5 && abs($0.bounds.minY - mark.written.minY) < 0.5
                        && abs($0.bounds.width - mark.written.width) < 0.5 && abs($0.bounds.height - mark.written.height) < 0.5
                }
                if !placed { problems.append("system engine: \(mark.kind.rawValue) on page \(index + 1) missing or misplaced") }
            }
            guard let pictureBefore = render(a, scale: 0.5), let pictureAfter = render(b, scale: 0.5) else {
                unrendered += 1
                continue
            }
            if expected.isEmpty {
                if difference(pictureBefore, pictureAfter).count != 0 { pictureChanged += 1 }
            } else {
                problems += checkMarkedPage(pictureBefore, pictureAfter, marks: expected, page: a, scale: 0.5, margin: 2,
                                            reader: "system engine", pageNumber: index + 1)
            }
        }
        if unreadable > 0 { problems.append("system engine: \(unreadable) pages could not be read, so they were not checked") }
        if unrendered > 0 { problems.append("system engine: \(unrendered) pages could not be rendered, so their pictures were not compared") }
        if textChanged > 0 { problems.append("system engine: text differs on \(textChanged) pages") }
        if geometryChanged > 0 { problems.append("system engine: size or rotation differs on \(geometryChanged) pages") }
        if lostAnnotations > 0 { problems.append("system engine: \(lostAnnotations) existing annotations lost") }
        if pictureChanged > 0 { problems.append("system engine: \(pictureChanged) untouched pages render differently") }
    }

    // poppler.
    let textBefore = run("\(popplerDirectory)/pdftotext", [originalURL.path, "-"], in: scratch)
    let textAfter = run("\(popplerDirectory)/pdftotext", [target.path, "-"], in: scratch)
    if !textBefore.launched || !textAfter.launched {
        problems.append("poppler could not be started — text not independently checked")
    } else {
        if textBefore.status != 0 || textAfter.status != 0 { problems.append("poppler: exit status \(textBefore.status) → \(textAfter.status)") }
        if textBefore.output != textAfter.output { problems.append("poppler: text differs") }
        if textBefore.output.isEmpty { problems.append("poppler: read no text at all, so nothing was compared") }
        if textBefore.messages != textAfter.messages { problems.append("poppler: its messages changed") }
    }
    func pageLines(_ info: ToolResult) -> [String] {
        String(decoding: info.output, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("Page ") }.map(String.init)
    }
    let infoBefore = run("\(popplerDirectory)/pdfinfo", ["-f", "1", "-l", "100000", originalURL.path], in: scratch)
    let infoAfter = run("\(popplerDirectory)/pdfinfo", ["-f", "1", "-l", "100000", target.path], in: scratch)
    if pageLines(infoBefore).isEmpty || pageLines(infoBefore) != pageLines(infoAfter) { problems.append("poppler: page sizes differ or could not be read") }
    if infoBefore.status != infoAfter.status || infoBefore.messages != infoAfter.messages { problems.append("poppler: pdfinfo ended or complained differently") }
    let renderBefore = run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", originalURL.path], in: scratch)
    let renderAfter = run("\(popplerDirectory)/pdftoppm", ["-r", "30", "-gray", target.path], in: scratch)
    if renderBefore.status != renderAfter.status || renderBefore.messages != renderAfter.messages { problems.append("poppler: pdftoppm ended or complained differently") }
    let renderedBefore = splitPGM(renderBefore.output)
    let renderedAfter = splitPGM(renderAfter.output)
    if renderedBefore.isEmpty || renderedBefore.count != renderedAfter.count || renderedBefore.count != before.pageCount {
        problems.append("poppler: could not render both files for comparison")
    } else {
        var changedPages = 0
        for index in 0..<renderedBefore.count {
            if let expected = marksByPage[index], let page = before.page(at: index) {
                // poppler draws a highlight with rounded ends that reach a little beyond its box.
                problems += checkMarkedPage(renderedBefore[index], renderedAfter[index], marks: expected, page: page, scale: 30.0 / 72.0,
                                            margin: 5, reader: "poppler", pageNumber: index + 1)
            } else if difference(renderedBefore[index], renderedAfter[index]).count != 0 {
                changedPages += 1
            }
        }
        if changedPages > 0 { problems.append("poppler: \(changedPages) untouched pages render differently") }
    }

    // MuPDF.
    let report = run(python, ["-I", mupdfHelper, originalURL.path, target.path], in: scratch)
    guard let parsed = try? JSONSerialization.jsonObject(with: report.output) as? [[String: Any]], parsed.count == 2 else {
        return problems + ["MuPDF helper could not be run — third reader did not check this file"]
    }
    let reportBefore = parsed[0], reportAfter = parsed[1]
    guard (reportBefore["ok"] as? Bool) == true, (reportAfter["ok"] as? Bool) == true else {
        return problems + ["MuPDF: cannot open (\(reportAfter["error"] as? String ?? "original unreadable"))"]
    }
    if (reportBefore["repaired"] as? Bool) != (reportAfter["repaired"] as? Bool) {
        problems.append("MuPDF: needs repair \(reportBefore["repaired"] ?? "?") → \(reportAfter["repaired"] ?? "?")")
    }
    if (reportBefore["warnings"] as? String) != (reportAfter["warnings"] as? String) { problems.append("MuPDF: its warnings changed") }
    let pagesBefore = reportBefore["pages"] as? [[String: Any]] ?? [], pagesAfter = reportAfter["pages"] as? [[String: Any]] ?? []
    guard pagesBefore.count == pagesAfter.count else {
        return problems + ["MuPDF: page count \(pagesBefore.count) → \(pagesAfter.count)"]
    }
    var textChanged = 0, geometryChanged = 0, otherItemsChanged = 0
    for index in 0..<pagesBefore.count {
        let a = pagesBefore[index], b = pagesAfter[index]
        if (a["text"] as? String) != (b["text"] as? String) { textChanged += 1 }
        if numbers(a["box"]) != numbers(b["box"]) || numbers(a["rotation"]) != numbers(b["rotation"]) { geometryChanged += 1 }
        for kind in ["links", "controls"] where (a[kind] as? [[Any]] ?? []).map(stable) != (b[kind] as? [[Any]] ?? []).map(stable) { otherItemsChanged += 1 }

        let newItems = b["annotations"] as? [[Any]] ?? []
        var remaining = newItems.map(stable)
        for old in (a["annotations"] as? [[Any]] ?? []).map(stable) {
            if let found = remaining.firstIndex(of: old) { remaining.remove(at: found) } else { problems.append("MuPDF: an existing annotation on page \(index + 1) was lost") }
        }
        let expected = marksByPage[index] ?? []
        if remaining.count != expected.count { problems.append("MuPDF: page \(index + 1) gained \(remaining.count) annotations, expected \(expected.count)") }
        // MuPDF measures from the top-left of the page; that conversion is only simple on an upright page.
        let page = before.page(at: index)
        let crop = page?.bounds(for: .cropBox) ?? .zero
        for mark in expected {
            let found = newItems.contains { item in
                guard (item.first as? String) == mark.kind.rawValue, item.count > 2, (item[2] as? String) == mark.note,
                      let box = (item[1] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), box.count == 4 else { return false }
                guard page?.rotation == 0 else { return true }
                let wanted = [mark.written.minX - crop.minX, crop.maxY - mark.written.maxY, mark.written.maxX - crop.minX, crop.maxY - mark.written.minY]
                return zip(box, wanted).allSatisfy { abs($0 - Double($1)) < 3 }
            }
            if !found { problems.append("MuPDF: \(mark.kind.rawValue) on page \(index + 1) missing or misplaced") }
        }
    }
    if textChanged > 0 { problems.append("MuPDF: text differs on \(textChanged) pages") }
    if geometryChanged > 0 { problems.append("MuPDF: size or rotation differs on \(geometryChanged) pages") }
    if otherItemsChanged > 0 { problems.append("MuPDF: links or form controls differ on \(otherItemsChanged) pages") }
    return problems
}

// MARK: - Main

let arguments = CommandLine.arguments

if arguments.count >= 5 && arguments[1] == "--slim" {
    exit(runSlimCopies(scratch: URL(fileURLWithPath: arguments[2]), helper: arguments[3], paths: Array(arguments.dropFirst(4))))
}

if arguments.count >= 5 && arguments[1] == "--pages" {
    exit(runPageEdits(scratch: URL(fileURLWithPath: arguments[2]), helper: arguments[3], paths: Array(arguments.dropFirst(4))))
}

if arguments.count >= 4 && arguments[1] == "--write" {
    do {
        let original = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let document = PDFDocument(data: original)
        let pages = arguments.dropFirst(4).compactMap { Int($0) }.map { $0 - 1 }
        let marks = (pages.isEmpty ? [0] : pages).enumerated().map { slot, page -> MarkupAddition in
            let box = document?.page(at: page)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
            let rect = CGRect(x: box.minX + 60, y: box.minY + 60 + CGFloat(slot) * 24, width: 120, height: 12)
            return MarkupAddition(pageIndex: page, lineRects: [rect], red: 1, green: 0.92, blue: 0.23, note: "知白 \(slot)")
        }
        try PDFAppendWriter.appending(marks, to: original).write(to: URL(fileURLWithPath: arguments[3]))
        print("written")
    } catch {
        print("not written: \(error)")
        exit(1)
    }
    exit(0)
}

// --open-check-memory old|new <file>: how much memory the check made when a file is opened takes at
// its height, read the old way (whole into memory, then copied) or the new (straight into the bytes
// checked), in a fresh process; phys_footprint, as footprint -p gives it.
if arguments.count == 4 && arguments[1] == "--open-check-memory" {
    func footprint() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
    let url = URL(fileURLWithPath: arguments[3])
    let before = footprint()
    let answer = autoreleasepool { () -> PDFAppendError? in
        arguments[2] == "old"
            ? ((try? Data(contentsOf: url)).map { PDFAppendWriter.reasonAnnotationsCannotBeSaved($0) } ?? .damaged("file could not be read"))
            : PDFAppendWriter.reasonAnnotationsCannotBeSaved(file: url)
    }
    let after = footprint()
    Thread.sleep(forTimeInterval: 5)
    let later = footprint()
    print(String(format: "%@: before %.1f MB, height %.1f MB (+%.1f), just after %.1f MB, 5 s later %.1f MB; %@", arguments[2], before.now, after.peak,
                 after.peak - before.now, after.now, later.now, answer.map { "\($0)" } ?? "can save"))
    exit(0)
}

// --open-check: the check made when a file is opened, read both ways (whole into memory, as before,
// and straight from the file), and whether the two answers agree.
if arguments.count >= 3 && arguments[1] == "--open-check" {
    for path in arguments.dropFirst(2) {
        let url = URL(fileURLWithPath: path)
        let before = (try? Data(contentsOf: url)).map { PDFAppendWriter.reasonAnnotationsCannotBeSaved($0) } ?? .damaged("file could not be read")
        let after = PDFAppendWriter.reasonAnnotationsCannotBeSaved(file: url)
        print("\(before == after ? "same" : "DIFFERENT")\t\(before.map { "\($0)" } ?? "can save")\t\(path)")
    }
    exit(0)
}

if arguments.count >= 3 && arguments[1] == "--triage" {
    for path in arguments.dropFirst(2) {
        var verdict = "ok"
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let box = CGRect(x: 60, y: 60, width: 120, height: 12)
            _ = try PDFAppendWriter.appending([MarkupAddition(pageIndex: 0, lineRects: [box], red: 1, green: 1, blue: 0)], to: data)
        } catch {
            verdict = "\(error)"
        }
        print("\(verdict)\t\(path)")
    }
    exit(0)
}

guard arguments.count >= 4 else {
    print("usage: luma-corpus-check <scratch-dir> <mupdf-facts.py> <file> [more files...]")
    exit(2)
}
let scratch = URL(fileURLWithPath: arguments[1])
let mupdfHelper = arguments[2]
let paths = Array(arguments.dropFirst(3))

var passed = 0
var turnedAway: [String: [String]] = [:]
var writerFailures: [String] = []
var checkFailures: [String] = []
/// Files that could not be read from disk or opened by the system engine at all. Not a refusal by
/// the writer: nothing was learned about them, so the run cannot count as clean.
var notExamined: [String] = []
var coverage: [String: Int] = [:]
func cover(_ label: String, _ condition: Bool) { if condition { coverage[label, default: 0] += 1 } }

for (index, path) in paths.enumerated() {
    autoreleasepool {
        let url = URL(fileURLWithPath: path)
        let label = String(url.lastPathComponent.prefix(46))
        guard let original = try? Data(contentsOf: url), let document = PDFDocument(url: url) else {
            notExamined.append(label)
            return
        }
        // Each mark gets its own slot so that marks sharing a page (short documents) never overlap.
        func mark(_ page: Int, _ note: String, slot: Int) -> Mark {
            let box = document.page(at: page)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
            return Mark(page: page, rect: CGRect(x: box.minX + 60, y: box.minY + 60 + CGFloat(slot) * 24, width: 120, height: 12), note: note)
        }
        func addition(_ m: Mark) -> MarkupAddition {
            MarkupAddition(pageIndex: m.page, kind: m.kind, lineRects: [m.rect], red: 1, green: 0.92, blue: 0.23, note: m.note)
        }

        let facts: PDFFileFacts
        let first: Data
        let firstMark = mark(0, "知白 A", slot: 0)
        do {
            facts = try PDFAppendWriter.facts(of: original)
            first = try PDFAppendWriter.appending([addition(firstMark)], to: original)
        } catch let error as PDFAppendError {
            if case .selfCheckFailed = error { writerFailures.append("\(label): \(error)") } else { turnedAway[error.description, default: []].append(label) }
            return
        } catch {
            writerFailures.append("\(label): \(error)")
            return
        }
        if facts.pageCount != document.pageCount {
            checkFailures.append("\(label): writer counts \(facts.pageCount) pages, system engine \(document.pageCount)")
            return
        }
        // The last of them a strikethrough, so that each file also carries one through the later saves.
        var strike = mark(facts.pageCount - 1, "知白 CCC", slot: 2)
        strike.kind = .strikeOut
        let laterMarks = [mark(facts.pageCount / 2, "知白 BB", slot: 1), strike]
        let second: Data
        do {
            second = try PDFAppendWriter.appending(laterMarks.map(addition), to: first)
        } catch {
            // The input here is the writer's own output, so any refusal is the writer's fault.
            writerFailures.append("\(label): second save failed — \(error)")
            return
        }

        cover("compressed index", facts.compressedIndex)
        cover("old-style index", !facts.compressedIndex)
        cover("hybrid index", facts.hybridIndex)
        cover("more than one index section (saved before, or linearized)", facts.indexSections > 1)
        cover("linearized", facts.linearized)
        cover("has freed objects", facts.freedObjects > 0)
        cover("has unused numbers marked in use at position 0", facts.placeholders > 0)
        cover("has objects that index sections disagree about (none of them needed here)", facts.contestedObjects > 0)
        cover("a page with non-zero generation", facts.pagesWithNonZeroGeneration > 0)
        cover("pages stored inside object packs", facts.pagesInsideObjectPacks > 0)
        cover("already carries annotations", (0..<document.pageCount).contains { !(document.page(at: $0)?.annotations.isEmpty ?? true) })
        cover("has a rotated page", (0..<document.pageCount).contains { (document.page(at: $0)?.rotation ?? 0) != 0 })

        var problems = check(originalURL: url, original: original, result: first, marks: [firstMark],
                             scratch: scratch, mupdfHelper: mupdfHelper, tag: "\(index)a").map { "after 1st save — \($0)" }
        problems += check(originalURL: url, original: original, result: second, marks: [firstMark] + laterMarks,
                          scratch: scratch, mupdfHelper: mupdfHelper, tag: "\(index)b").map { "after 2nd save — \($0)" }
        if !(second.prefix(first.count) == first) { problems.append("2nd save did not preserve the 1st save's bytes") }

        // Third save: change one mark the writer put there, delete another. The writer finds them
        // by kind and rectangle; the rectangle in the file is the drawing's.
        func key(_ m: Mark) -> ExistingMarkup {
            ExistingMarkup(kind: .highlight, rect: MarkupAppearance.drawing(kind: .highlight, quads: [MarkupQuad(m.rect)], red: 1, green: 0.92, blue: 0.23).bounds)
        }
        let changedFirst = Mark(page: firstMark.page, rect: firstMark.rect, note: "知白 A 改")
        do {
            let third = try PDFAppendWriter.applying([
                .modify(page: firstMark.page, original: key(firstMark), colour: MarkupColour(red: 0.45, green: 0.7, blue: 1), note: .set(changedFirst.note)),
                .remove(page: laterMarks[0].page, original: key(laterMarks[0])),
            ], to: second)
            problems += check(originalURL: url, original: original, result: third, marks: [changedFirst, laterMarks[1]],
                              scratch: scratch, mupdfHelper: mupdfHelper, tag: "\(index)c").map { "after 3rd save (change, delete) — \($0)" }
            if !(third.prefix(second.count) == second) { problems.append("3rd save did not preserve the 2nd save's bytes") }
        } catch {
            writerFailures.append("\(label): third save (change, delete) failed — \(error)")
            return
        }

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
print("could not be examined at all (missing, unreadable, or not a PDF): \(notExamined.count)")
notExamined.prefix(10).forEach { print("  ! \($0)") }
print("WRITER FAILURES (its own output was bad): \(writerFailures.count)")
writerFailures.prefix(20).forEach { print("  ! \($0)") }
print("handled but failed a check: \(checkFailures.count)")
checkFailures.prefix(30).forEach { print("  ! \($0)") }
print("page readings skipped because the system engine reads the original inconsistently: \(unstablePages)")
print("marked pages whose change was counted but not located, because the page is rotated: \(placeUncheckedPages)")
print("kinds of file among those handled:")
for (label, count) in coverage.sorted(by: { $0.value > $1.value }) { print("  \(count) × \(label)") }
if passed == 0 { print("NOTHING PASSED: no file was actually written and checked.") }
exit(writerFailures.isEmpty && checkFailures.isEmpty && notExamined.isEmpty && passed > 0 ? 0 : 1)
