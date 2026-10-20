import CoreGraphics
import Foundation

/// A highlight, underline or strikethrough to add to a page.
public struct MarkupAddition {
    /// The kind of mark, named as the file names it (the annotation's subtype).
    public enum Kind: String, CaseIterable {
        case highlight = "Highlight"
        case underline = "Underline"
        case strikeOut = "StrikeOut"
    }

    public var pageIndex: Int
    public var kind: Kind
    /// One quad per line of marked text, in the page's own coordinates.
    public var quads: [MarkupQuad]
    public var red: Double
    public var green: Double
    public var blue: Double
    /// The note attached to the mark, if any.
    public var note: String?

    public init(pageIndex: Int, kind: Kind = .highlight, quads: [MarkupQuad],
                red: Double, green: Double, blue: Double, note: String? = nil) {
        self.pageIndex = pageIndex
        self.kind = kind
        self.quads = quads
        self.red = red
        self.green = green
        self.blue = blue
        self.note = note
    }

    /// For upright text: one rectangle per line.
    public init(pageIndex: Int, kind: Kind = .highlight, lineRects: [CGRect],
                red: Double, green: Double, blue: Double, note: String? = nil) {
        self.init(pageIndex: pageIndex, kind: kind, quads: lineRects.map(MarkupQuad.init), red: red, green: green, blue: blue, note: note)
    }
}

/// How the writer finds a highlight or underline that is already in the file: by its kind and the
/// rectangle the file records for it.
public struct ExistingMarkup: Equatable {
    public var kind: MarkupAddition.Kind
    public var rect: CGRect

    public init(kind: MarkupAddition.Kind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }
}

/// A mark's colour, each part from 0 to 1.
public struct MarkupColour: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        func clamped(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        self.red = clamped(red)
        self.green = clamped(green)
        self.blue = clamped(blue)
    }
}

/// What a change does to a mark's note.
public enum NoteChange: Equatable {
    /// The note in the file stays exactly as it is, byte for byte.
    case unchanged
    /// The note becomes this text; nil or empty removes it.
    case set(String?)
}

/// One change to the annotations of a document.
public enum MarkupChange {
    case add(MarkupAddition)
    /// Changes an existing highlight or underline: a new colour (nil keeps its colour and drawing as
    /// they are), and its note. What is not changed is copied from the file untouched.
    case modify(page: Int, original: ExistingMarkup, colour: MarkupColour?, note: NoteChange)
    case remove(page: Int, original: ExistingMarkup)

    public var pageIndex: Int {
        switch self {
        case .add(let addition): return addition.pageIndex
        case .modify(let page, _, _, _), .remove(let page, _): return page
        }
    }
}

/// How a file is built. Used to report which kinds of file the writer has been exercised on.
public struct PDFFileFacts {
    public var pageCount = 0
    public var indexSections = 0
    public var compressedIndex = false
    public var hybridIndex = false
    public var linearized = false
    public var freedObjects = 0
    public var pagesWithNonZeroGeneration = 0
    public var pagesInsideObjectPacks = 0
    /// Unused numbers recorded as "in use at position 0", the way macOS's own PDF writer does.
    public var placeholders = 0
    /// Numbers whose index sections conflict. The writer refuses only if it needs one of them.
    public var contestedObjects = 0
    /// Pages listed in a lower branch of the page tree rather than by its root.
    public var pagesBelowBranches = 0
    /// Pages that take their resources, size or turn from a lower branch of the page tree.
    public var pagesInheritingFromBranches = 0
}

/// Saves annotations by appending to the original file (a PDF "incremental update").
///
/// Every byte of the original is kept as it is; the new objects and a new index section go after
/// it. The writer refuses any file it does not fully understand rather than risk a bad write.
public enum PDFAppendWriter {

    public static func facts(of original: Data) throws -> PDFFileFacts {
        let structure = try PDFStructure([UInt8](original))
        let pages = try structure.pageNumbers()
        var facts = PDFFileFacts()
        facts.pageCount = pages.count
        facts.indexSections = structure.sectionCount
        facts.compressedIndex = structure.newestIsStream
        facts.hybridIndex = structure.isHybrid
        facts.linearized = structure.isLinearized
        facts.freedObjects = structure.freedObjectCount
        facts.placeholders = structure.placeholderCount
        facts.contestedObjects = structure.contested.count
        if let root = try structure.catalog()["Pages"]?.reference?.number {
            for (page, parent) in try structure.listingParents() where parent != root {
                facts.pagesBelowBranches += 1
                let value = try structure.object(page)
                for key in ["Resources", "MediaBox", "CropBox", "Rotate"] where value[key] == nil {
                    if let found = try PDFPageWriter.inherited(key, from: value, in: structure), found.holder != root {
                        facts.pagesInheritingFromBranches += 1
                        break
                    }
                }
            }
        }
        for number in pages {
            switch structure.entries[number] {
            case .offset(_, let generation)? where generation != 0: facts.pagesWithNonZeroGeneration += 1
            case .compressed?: facts.pagesInsideObjectPacks += 1
            default: break
            }
        }
        return facts
    }

    /// Why annotations could not be saved into this file, or nil if they can. Checked when a
    /// document is opened, so that the reader is told before marking anything.
    public static func reasonAnnotationsCannotBeSaved(_ original: Data) -> PDFAppendError? {
        reasonAnnotationsCannotBeSaved(bytes: [UInt8](original))
    }

    /// The same, read straight from the file: one copy of its bytes, not two, and none mapped (a
    /// mapped file cut short by another program meanwhile would bring the reader down). A file cut
    /// short while it is read is checked as it was read, and found damaged.
    public static func reasonAnnotationsCannotBeSaved(file: URL) -> PDFAppendError? {
        switch readWhole(file) {
        case .read(let bytes): return reasonAnnotationsCannotBeSaved(bytes: bytes)
        case .tooLarge: return .refused("file is larger than 4 GB")
        case .unreadable: return .damaged("file could not be read")
        }
    }

    enum WholeFile { case read([UInt8]), tooLarge, unreadable }

    static func readWhole(_ file: URL) -> WholeFile {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0 else { return .unreadable }
        // A file the strict reader would refuse for its size is not read at all, so as not to hold it.
        guard info.st_size < Int64(PDFStructure.sizeLimit) else { return .tooLarge }
        let size = Int(info.st_size)
        var failed = false
        let bytes = [UInt8](unsafeUninitializedCapacity: size) { buffer, count in
            var done = 0
            while done < size, let base = buffer.baseAddress {
                let got = read(descriptor, base + done, size - done)
                if got < 0 && errno == EINTR { continue }
                if got < 0 { failed = true }
                if got <= 0 { break }
                done += got
            }
            count = done
        }
        return failed ? .unreadable : .read(bytes)
    }

    static func reasonAnnotationsCannotBeSaved(bytes: [UInt8]) -> PDFAppendError? {
        do {
            let structure = try PDFStructure(bytes)
            if let reason = try structure.refusalReason() { return .refused(reason) }
            _ = try structure.pageNumbers()
            return nil
        } catch let error as PDFAppendError {
            return error
        } catch {
            return .damaged("\(error)")
        }
    }

    /// Returns the original bytes followed by an update that adds the given marks.
    public static func appending(_ additions: [MarkupAddition], to original: Data) throws -> Data {
        try applying(additions.map(MarkupChange.add), to: original, sizeLimit: PDFStructure.sizeLimit)
    }

    /// The same, with the size ceiling as a parameter so that it can be tested without a 4 GB file.
    static func appending(_ additions: [MarkupAddition], to original: Data, sizeLimit: Int) throws -> Data {
        try applying(additions.map(MarkupChange.add), to: original, sizeLimit: sizeLimit)
    }

    /// Returns the original bytes followed by an update that makes the given changes.
    public static func applying(_ changes: [MarkupChange], to original: Data) throws -> Data {
        try applying(changes, to: original, sizeLimit: PDFStructure.sizeLimit)
    }

    /// The same, also giving the rectangle each new mark was written with, in the order the additions
    /// come in `changes`. The app gives its marks these very rectangles, so that a later change or
    /// removal finds them in the file.
    public static func applyingReportingRects(_ changes: [MarkupChange], to original: Data) throws -> (data: Data, newRects: [CGRect]) {
        try applyingReportingRects(changes, to: original, sizeLimit: PDFStructure.sizeLimit)
    }

    static func applying(_ changes: [MarkupChange], to original: Data, sizeLimit: Int) throws -> Data {
        try applyingReportingRects(changes, to: original, sizeLimit: sizeLimit).data
    }

    static func applyingReportingRects(_ changes: [MarkupChange], to original: Data, sizeLimit: Int) throws -> (data: Data, newRects: [CGRect]) {
        guard !changes.isEmpty else { return (original, []) }
        let bytes = [UInt8](original)
        let structure = try PDFStructure(bytes, sizeLimit: sizeLimit)
        if let reason = try structure.refusalReason() { throw PDFAppendError.refused(reason) }
        let pages = try structure.pageNumbers()
        guard let rootRaw = structure.trailer["Root"]?.raw else { throw PDFAppendError.damaged("trailer does not name the document root") }

        var pageOrder: [Int] = []
        var byPage: [Int: [(position: Int, change: MarkupChange)]] = [:]
        for (position, change) in changes.enumerated() {
            guard change.pageIndex >= 0, change.pageIndex < pages.count else { throw PDFAppendError.refusedChange(position, "the page to annotate does not exist") }
            if case .add(let addition) = change {
                let numbers = addition.quads.flatMap(\.points).flatMap { [$0.x, $0.y] }
                let colour = [addition.red, addition.green, addition.blue].map { CGFloat($0) }
                guard !addition.quads.isEmpty, MarkupAppearance.usable(numbers), MarkupAppearance.usable(colour) else {
                    throw PDFAppendError.refusedChange(position, "the annotation has no usable area")
                }
            }
            if byPage[change.pageIndex] == nil { pageOrder.append(change.pageIndex) }
            byPage[change.pageIndex, default: []].append((position, change))
        }

        // The index reader has already made sure the declared size is a sane number.
        var nextNumber = max(structure.trailer["Size"]?.int ?? 0, (structure.entries.keys.max() ?? 0) + 1)
        // At most two numbers per change (an annotation and its drawing), plus one for a compressed index.
        guard nextNumber + 2 * changes.count + 1 <= PDFStructure.maximumObjectNumber else {
            throw PDFAppendError.refused("file has no object numbers left")
        }
        var out = bytes
        if let last = out.last, last != 10 && last != 13 { out.append(10) }
        func emit(_ text: String) { out.append(contentsOf: Array(text.utf8)) }

        var written: [(number: Int, generation: Int, offset: Int)] = []
        var expectations: [Expectation] = []
        let stamp = dateStamp()
        // An annotation listed on two pages is still one annotation: it may be changed only once.
        var claimed = Set<Int>()
        // The rectangle of each new mark, by its place in `changes`.
        var newRects: [Int: CGRect] = [:]

        /// Writes the drawing of a mark as a separate object and returns its number.
        func writeDrawing(_ drawing: MarkupAppearance.Drawing) -> Int {
            let number = nextNumber
            nextNumber += 1
            let resources = drawing.multiplies ? "<< /ExtGState << /GS0 << /Type /ExtGState /BM /Multiply >> >> >>" : "<< >>"
            let content = Array(drawing.content.utf8)
            let b = drawing.bounds
            written.append((number, 0, out.count))
            emit("\(number) 0 obj\n<< /Type /XObject /Subtype /Form /BBox [\(n(b.minX)) \(n(b.minY)) \(n(b.maxX)) \(n(b.maxY))] /Resources \(resources) /Length \(content.count) >>\nstream\n")
            out.append(contentsOf: content)
            emit("\nendstream\nendobj\n")
            return number
        }

        for pageIndex in pageOrder {
            let pageNumber = pages[pageIndex]
            let pageValue = try structure.object(pageNumber)
            guard let pageEntries = pageValue.entries else { throw PDFAppendError.damaged("page is not a dictionary") }
            guard Set(pageEntries.map(\.key)).count == pageEntries.count else { throw PDFAppendError.damaged("page lists the same property twice") }
            var pageGeneration = 0
            if case .offset(_, let generation)? = structure.entries[pageNumber] { pageGeneration = generation }

            // What the page already carries is copied out byte for byte, minus anything removed.
            var existing: [PDFValue] = []
            if let annotations = pageValue["Annots"] {
                let resolved = try structure.resolve(annotations)
                if let items = resolved.array {
                    for item in items {
                        guard item.reference != nil || item.entries != nil else {
                            throw PDFAppendError.damaged("page's annotation list holds something that is not an annotation")
                        }
                        existing.append(item)
                    }
                } else if !resolved.isNull {
                    throw PDFAppendError.damaged("page's annotation list is not a list")
                }
            }

            var removedNumbers = Set<Int>()
            // Annotations written straight into the page's list rather than as objects of their own
            // are known by their place in it: those removed, and those changed with their new text.
            var removedPlaces = Set<Int>()
            var rewritten: [Int: [UInt8]] = [:]
            var claimedPlaces = Set<Int>()
            var listedChanges: [(place: Int, check: (Int) -> Expectation)] = []
            var added: [(number: Int, kind: MarkupAddition.Kind)] = []
            let rotation = try pageRotation(pageValue, in: structure)
            for (position, change) in byPage[pageIndex] ?? [] {
                // A change the writer will not make is reported as that change, so that the rest can be saved without it.
                do {
                    switch change {
                    case .add(let addition):
                        // The reader's own marks name their corners as the text reads.
                        let drawing = MarkupAppearance.drawing(kind: addition.kind, quads: addition.quads, red: addition.red, green: addition.green,
                                                               blue: addition.blue, rotation: rotation, corners: .asTheTextReads)
                        let drawingNumber = writeDrawing(drawing)
                        let number = nextNumber
                        nextNumber += 1
                        written.append((number, 0, out.count))
                        emit("\(number) 0 obj\n\(annotationBody(addition, bounds: drawing.bounds, drawingNumber: drawingNumber, pageNumber: pageNumber, pageGeneration: pageGeneration, stamp: stamp))\nendobj\n")
                        added.append((number, addition.kind))
                        newRects[position] = drawing.bounds
                        expectations.append(.added(number, addition.kind, rect: drawing.bounds, drawing: drawingNumber,
                                                   contents: addition.note.flatMap { $0.isEmpty ? nil : Array(textString($0).utf8) }))

                    case .remove(_, let original):
                        let target = try find(original, among: existing, claimed: claimed, claimedPlaces: claimedPlaces, in: structure)
                        claimedPlaces.insert(target.place)
                        guard let number = target.number else {
                            // Written straight into the list: nothing else can refer to it. Checked
                            // afterwards by its own text, which no other annotation in the list has.
                            removedPlaces.insert(target.place)
                            expectations.append(.gone(page: pageNumber, raw: Array(existing[target.place].raw)))
                            continue
                        }
                        claimed.insert(number)
                        // Replies to it would be left answering nothing: such a mark is left for a program
                        // that deals with discussions.
                        for item in existing where item.reference?.number != number {
                            if try structure.resolve(item)["IRT"]?.reference?.number == number {
                                throw PDFAppendError.refused("the annotation has replies")
                            }
                        }
                        removedNumbers.insert(number)
                        // Its pop-up window goes with it, but only if that really is its own pop-up.
                        if let popup = target.value["Popup"]?.reference, popup.number != number,
                           let window = try? structure.resolve(target.value["Popup"]!), window["Subtype"]?.name == "Popup",
                           window["Parent"]?.reference?.number == number {
                            removedNumbers.insert(popup.number)
                        }

                    case .modify(_, let original, let colour, let note):
                        let target = try find(original, among: existing, claimed: claimed, claimedPlaces: claimedPlaces, in: structure)
                        claimedPlaces.insert(target.place)
                        if let number = target.number { claimed.insert(number) }
                        let rect = try annotationRect(target.value, in: structure) ?? original.rect
                        var replaced: Set<String> = ["M"]
                        var additions = " /M (\(stamp))"
                        var drawingNumber: Int?
                        if let colour {
                            // Drawn over the lines the file records for it, inside the rectangle it already has.
                            let quadNumbers = try target.value["QuadPoints"].map { try structure.resolve($0) }?.array?.compactMap(\.number)
                            var quads = quadNumbers.flatMap(MarkupQuad.quads(from:)) ?? []
                            let margin = max(4, max(rect.width, rect.height) * 0.1)
                            if quads.isEmpty || !MarkupAppearance.usable(quads.flatMap(\.points).flatMap { [$0.x, $0.y] })
                                || !quads.allSatisfy({ rect.insetBy(dx: -margin, dy: -margin).contains(MarkupAppearance.box($0)) }) {
                                quads = [MarkupQuad(rect)]
                            }
                            let drawing = MarkupAppearance.drawing(kind: original.kind, quads: quads, red: colour.red, green: colour.green,
                                                                   blue: colour.blue, rotation: rotation, frame: rect, corners: .fromAFile)
                            drawingNumber = writeDrawing(drawing)
                            replaced.formUnion(["C", "AP"])
                            additions += " /C [\(c(colour.red)) \(c(colour.green)) \(c(colour.blue))] /AP << /N \(drawingNumber!) 0 R >>"
                        }
                        var writtenNote: [UInt8]?
                        if case .set(let text) = note {
                            // A note in rich text (/RC) would go on showing the old words: it goes too.
                            replaced.formUnion(["Contents", "RC"])
                            if let text, !text.isEmpty {
                                additions += " /Contents \(textString(text))"
                                writtenNote = Array(textString(text).utf8)
                            }
                        }
                        // Everything the annotation had is kept, except what this change replaces.
                        var body = Array("<<".utf8)
                        for entry in target.value.entries ?? [] where !replaced.contains(entry.key) {
                            body.append(32)
                            body.append(contentsOf: entry.rawKey)
                            body.append(32)
                            body.append(contentsOf: entry.value.raw)
                        }
                        body.append(contentsOf: Array((additions + " >>").utf8))
                        let keptNote = note == .unchanged ? target.value["Contents"].map { Array($0.raw) } : nil
                        let rectBytes = target.value["Rect"].map { Array($0.raw) } ?? []
                        func check(_ location: Expectation.Location) -> Expectation {
                            .changed(location, rect: rectBytes, colour: colour, drawing: drawingNumber,
                                     note: note == .unchanged ? keptNote : writtenNote, noteKept: note == .unchanged)
                        }
                        if let number = target.number {
                            var generation = 0
                            if case .offset(_, let g)? = structure.entries[number] { generation = g }
                            written.append((number, generation, out.count))
                            emit("\(number) \(generation) obj\n")
                            out.append(contentsOf: body)
                            emit("\nendobj\n")
                            expectations.append(check(.object(number, page: pageNumber)))
                        } else {
                            // Written straight into the list, it is changed there.
                            rewritten[target.place] = body
                            listedChanges.append((target.place, { check(.listed(page: pageNumber, at: $0)) }))
                        }
                    }
                } catch PDFAppendError.refused(let why) {
                    throw PDFAppendError.refusedChange(position, why)
                }
            }

            let kept = existing.enumerated().filter { place, item in
                !removedPlaces.contains(place) && !(item.reference.map { removedNumbers.contains($0.number) } ?? false)
            }
            written.append((pageNumber, pageGeneration, out.count))
            emit("\(pageNumber) \(pageGeneration) obj\n<<")
            for entry in pageEntries where entry.key != "Annots" {
                emit(" ")
                out.append(contentsOf: entry.rawKey)
                emit(" ")
                out.append(contentsOf: entry.value.raw)
            }
            emit(" /Annots [")
            for (place, item) in kept {
                emit(" ")
                out.append(contentsOf: rewritten[place] ?? Array(item.raw))
            }
            for item in added { emit(" \(item.number) 0 R") }
            emit(" ] >>\nendobj\n")
            expectations.append(.list(page: pageNumber, count: kept.count + added.count, without: removedNumbers))
            for (place, check) in listedChanges {
                guard let at = kept.firstIndex(where: { $0.offset == place }) else { throw PDFAppendError.selfCheckFailed("a changed annotation was dropped") }
                expectations.append(check(at))
            }
        }

        appendIndex(to: &out, written: written, nextNumber: nextNumber, structure: structure, rootRaw: rootRaw)

        guard out.count < sizeLimit else { throw PDFAppendError.refused("file would grow past 4 GB") }
        try selfCheck(out, original: bytes, pages: pages, expectations: expectations)
        return (Data(out), changes.indices.compactMap { newRects[$0] })
    }

    /// Ends an update: the index section listing every object version written in it, and the
    /// trailer, in the same kind of index as the file's newest one. Shared by every writer that
    /// appends to a file.
    static func appendIndex(to out: inout [UInt8], written: [(number: Int, generation: Int, offset: Int)], nextNumber: Int,
                            structure: PDFStructure, rootRaw: ArraySlice<UInt8>) {
        var written = written
        var nextNumber = nextNumber
        func emit(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
        func emitCarriedTrailerKeys() {
            emit(" /Root ")
            out.append(contentsOf: rootRaw)
            emit(" /Prev \(structure.newestXrefOffset)")
            for key in ["Info", "ID"] {
                if let value = structure.trailer[key] {
                    emit(" /\(key) ")
                    out.append(contentsOf: value.raw)
                }
            }
        }

        let xrefOffset = out.count
        if structure.newestIsStream {
            // A file indexed by compressed indexes must be extended with another one, which lists itself too.
            written.append((nextNumber, 0, xrefOffset))
            nextNumber += 1
        }
        let sorted = written.sorted { $0.number < $1.number }
        var runs: [[(number: Int, generation: Int, offset: Int)]] = []
        for item in sorted {
            if let last = runs.last?.last, last.number + 1 == item.number {
                runs[runs.count - 1].append(item)
            } else {
                runs.append([item])
            }
        }

        if structure.newestIsStream {
            var rows: [UInt8] = []
            for item in sorted {
                rows.append(1)
                for shift in [24, 16, 8, 0] { rows.append(UInt8((item.offset >> shift) & 0xFF)) }
                rows.append(UInt8((item.generation >> 8) & 0xFF))
                rows.append(UInt8(item.generation & 0xFF))
            }
            let ranges = runs.map { "\($0[0].number) \($0.count)" }.joined(separator: " ")
            emit("\(nextNumber - 1) 0 obj\n<< /Type /XRef /Size \(nextNumber) /W [1 4 2] /Index [\(ranges)]")
            emitCarriedTrailerKeys()
            emit(" /Length \(rows.count) >>\nstream\n")
            out.append(contentsOf: rows)
            emit("\nendstream\nendobj\n")
        } else {
            emit("xref\n")
            for run in runs {
                emit("\(run[0].number) \(run.count)\n")
                // Each entry is exactly 20 bytes: 10-digit position, 5-digit generation, "n", line end.
                for item in run { emit("\(zeroPadded(item.offset, 10)) \(zeroPadded(item.generation, 5)) n \n") }
            }
            emit("trailer\n<< /Size \(nextNumber)")
            emitCarriedTrailerKeys()
            emit(" >>\n")
        }
        emit("startxref\n\(xrefOffset)\n%%EOF\n")
    }

    /// The one existing annotation a change is about: its place in the page's list, its number if it
    /// is an object of its own (not written straight into the list), and what it holds. Two that
    /// match equally well, or none, and the writer refuses rather than change the wrong one.
    private static func find(_ original: ExistingMarkup, among items: [PDFValue], claimed: Set<Int>, claimedPlaces: Set<Int>,
                             in structure: PDFStructure) throws -> (place: Int, number: Int?, value: PDFValue) {
        var matches: [(place: Int, number: Int?, value: PDFValue)] = []
        for (place, item) in items.enumerated() {
            let value = try structure.resolve(item)
            guard value["Subtype"]?.name == original.kind.rawValue,
                  let box = try value["Rect"].map({ try structure.resolve($0) })?.array?.compactMap(\.number), box.count == 4 else { continue }
            let rect = CGRect(x: min(box[0], box[2]), y: min(box[1], box[3]), width: abs(box[2] - box[0]), height: abs(box[3] - box[1]))
            let close = abs(rect.minX - original.rect.minX) <= 0.5 && abs(rect.minY - original.rect.minY) <= 0.5
                && abs(rect.maxX - original.rect.maxX) <= 0.5 && abs(rect.maxY - original.rect.maxY) <= 0.5
            if close { matches.append((place, item.reference?.number, value)) }
        }
        guard !matches.isEmpty else { throw PDFAppendError.refused("the annotation to change is not in the file") }
        guard matches.count == 1 else { throw PDFAppendError.refused("two annotations match equally, so it is not clear which to change") }
        guard !claimedPlaces.contains(matches[0].place), !(matches[0].number.map(claimed.contains) ?? false) else {
            throw PDFAppendError.refused("the same annotation is changed twice in one save")
        }
        return matches[0]
    }

    /// An annotation's rectangle, if the file gives a usable one.
    private static func annotationRect(_ value: PDFValue, in structure: PDFStructure) throws -> CGRect? {
        guard let box = try value["Rect"].map({ try structure.resolve($0) })?.array?.compactMap(\.number), box.count == 4,
              MarkupAppearance.usable(box.map { CGFloat($0) }) else { return nil }
        return CGRect(x: min(box[0], box[2]), y: min(box[1], box[3]), width: abs(box[2] - box[0]), height: abs(box[3] - box[1]))
    }

    /// How far the page is turned when shown: its own /Rotate, or one it inherits from the page tree.
    static func pageRotation(_ page: PDFValue, in structure: PDFStructure) throws -> Int {
        var node = page
        for _ in 0..<32 {
            if let turn = try node["Rotate"].map({ try structure.resolve($0) })?.int {
                // A turn that is not a quarter turn is taken to the nearest one, halfway rounding up,
                // as the system engine shows it (45 is shown as 90, -45 as 0).
                let quarters = Int(((Double(turn) + 45) / 90).rounded(.down))
                return ((quarters * 90 % 360) + 360) % 360
            }
            guard let parent = node["Parent"], parent.reference != nil else { return 0 }
            node = try structure.resolve(parent)
        }
        return 0
    }

    enum Expectation {
        /// A page's annotation list: how long it must be, and numbers that must no longer be in it.
        case list(page: Int, count: Int, without: Set<Int>)
        /// An annotation written straight into a page's list, removed: no item of the list has its text.
        case gone(page: Int, raw: [UInt8])
        /// A new mark: its kind, rectangle, drawing and note (the exact bytes written, or none).
        case added(Int, MarkupAddition.Kind, rect: CGRect, drawing: Int, contents: [UInt8]?)
        /// A changed mark: its rectangle unchanged (raw bytes), its new colour and drawing if the colour
        /// changed, and its note: the bytes it must have (the file's own, when kept), or none.
        case changed(Location, rect: [UInt8], colour: MarkupColour?, drawing: Int?, note: [UInt8]?, noteKept: Bool)

        /// Where a changed mark is: an object of its own listed on a page, or written straight into
        /// the page's list at a place.
        enum Location {
            case object(Int, page: Int)
            case listed(page: Int, at: Int)
        }
    }

    /// Reads the result back with the same strict reader before anyone else sees it.
    static func selfCheck(_ out: [UInt8], original: [UInt8], pages: [Int], expectations: [Expectation]) throws {
        do {
            let preserved = out.count > original.count && out.withUnsafeBytes { o in original.withUnsafeBytes { memcmp(o.baseAddress!, $0.baseAddress!, $0.count) == 0 } }
            guard preserved else {
                throw PDFAppendError.selfCheckFailed("original bytes were not preserved")
            }
            let result = try PDFStructure(out)
            guard try result.pageNumbers() == pages else { throw PDFAppendError.selfCheckFailed("pages changed") }
            func drawingIsSound(_ number: Int, frame: CGRect) throws -> Bool {
                let stream = try result.object(number)
                guard stream["Subtype"]?.name == "Form", let box = stream["BBox"]?.array?.compactMap(\.number), box.count == 4,
                      MarkupAppearance.usable(box.map { CGFloat($0) }) else { return false }
                return abs(box[0] - frame.minX) < 0.01 && abs(box[1] - frame.minY) < 0.01
                    && abs(box[2] - frame.maxX) < 0.01 && abs(box[3] - frame.maxY) < 0.01
            }
            for expectation in expectations {
                switch expectation {
                case .list(let page, let count, let without):
                    guard let list = try result.object(page)["Annots"]?.array, list.count == count else {
                        throw PDFAppendError.selfCheckFailed("annotation list is not what was written")
                    }
                    guard !list.contains(where: { $0.reference.map { without.contains($0.number) } ?? false }) else {
                        throw PDFAppendError.selfCheckFailed("a removed annotation is still listed")
                    }
                case .gone(let page, let raw):
                    guard let list = try result.object(page)["Annots"]?.array else {
                        throw PDFAppendError.selfCheckFailed("annotation list is not what was written")
                    }
                    guard !list.contains(where: { $0.reference == nil && Array($0.raw) == raw }) else {
                        throw PDFAppendError.selfCheckFailed("a removed annotation is still listed")
                    }
                case .added(let number, let kind, let rect, let drawing, let contents):
                    let annotation = try result.object(number)
                    guard annotation["Subtype"]?.name == kind.rawValue, try annotationRect(annotation, in: result).map({
                        abs($0.minX - rect.minX) < 0.01 && abs($0.minY - rect.minY) < 0.01 && abs($0.maxX - rect.maxX) < 0.01 && abs($0.maxY - rect.maxY) < 0.01
                    }) == true else {
                        throw PDFAppendError.selfCheckFailed("new annotation cannot be found")
                    }
                    guard annotation["Contents"].map({ Array($0.raw) }) == contents else {
                        throw PDFAppendError.selfCheckFailed("new annotation's note does not read back")
                    }
                    guard annotation["AP"]?["N"]?.reference?.number == drawing, try drawingIsSound(drawing, frame: rect) else {
                        throw PDFAppendError.selfCheckFailed("new annotation's drawing does not read back")
                    }
                case .changed(let location, let rectBytes, let colour, let drawing, let note, let noteKept):
                    let annotation: PDFValue
                    switch location {
                    case .object(let number, let page):
                        annotation = try result.object(number)
                        guard try result.object(page)["Annots"]?.array?.contains(where: { $0.reference?.number == number }) == true else {
                            throw PDFAppendError.selfCheckFailed("changed annotation is no longer listed")
                        }
                    case .listed(let page, let at):
                        guard let list = try result.object(page)["Annots"]?.array, list.indices.contains(at),
                              list[at].reference == nil, list[at].entries != nil else {
                            throw PDFAppendError.selfCheckFailed("changed annotation is no longer listed")
                        }
                        annotation = list[at]
                    }
                    guard annotation["Rect"].map({ Array($0.raw) }) == rectBytes else {
                        throw PDFAppendError.selfCheckFailed("changed annotation moved")
                    }
                    if let colour {
                        let read = annotation["C"]?.array?.compactMap(\.number) ?? []
                        guard read.count == 3, abs(read[0] - colour.red) < 0.001, abs(read[1] - colour.green) < 0.001, abs(read[2] - colour.blue) < 0.001 else {
                            throw PDFAppendError.selfCheckFailed("changed annotation does not read back as changed")
                        }
                        guard let drawing, annotation["AP"]?["N"]?.reference?.number == drawing,
                              let frame = try annotationRect(annotation, in: result), try drawingIsSound(drawing, frame: frame) else {
                            throw PDFAppendError.selfCheckFailed("changed annotation's drawing does not read back")
                        }
                    }
                    guard annotation["Contents"].map({ Array($0.raw) }) == note else {
                        throw PDFAppendError.selfCheckFailed(noteKept ? "a note that was not to change changed" : "changed note does not read back")
                    }
                    if !noteKept && annotation["RC"] != nil { throw PDFAppendError.selfCheckFailed("an old rich-text note was left behind") }
                }
            }
        } catch let error as PDFAppendError {
            if case .selfCheckFailed = error { throw error }
            throw PDFAppendError.selfCheckFailed(error.description)
        }
    }

    /// Kept for the tests written against the first version of the self-check.
    static func selfCheck(_ out: [UInt8], original: [UInt8], pages: [Int], expectedAnnotationCounts: [Int: Int]) throws {
        try selfCheck(out, original: original, pages: pages,
                      expectations: expectedAnnotationCounts.map { .list(page: $0.key, count: $0.value, without: []) })
    }

    private static func n(_ value: CGFloat) -> String { MarkupAppearance.number(value) }
    private static func c(_ value: Double) -> String { MarkupAppearance.number(CGFloat(min(max(value, 0), 1))) }

    /// Text stored as UTF-16 with a byte-order mark, so that any language survives.
    private static func textString(_ text: String) -> String {
        "<" + text.utf16.reduce(into: "FEFF") { $0 += String(format: "%04X", $1) } + ">"
    }

    private static func annotationBody(_ addition: MarkupAddition, bounds: CGRect, drawingNumber: Int,
                                       pageNumber: Int, pageGeneration: Int, stamp: String) -> String {
        // Four corners per line: top-left, top-right, bottom-left, bottom-right.
        let corners = addition.quads.flatMap(\.points).flatMap { [$0.x, $0.y] }
        var body = "<< /Type /Annot /Subtype /\(addition.kind.rawValue)"
        body += " /Rect [\(n(bounds.minX)) \(n(bounds.minY)) \(n(bounds.maxX)) \(n(bounds.maxY))]"
        body += " /QuadPoints [\(corners.map(n).joined(separator: " "))]"
        body += " /C [\(c(addition.red)) \(c(addition.green)) \(c(addition.blue))] /F 4"
        body += " /NM (\(UUID().uuidString)) /M (\(stamp))"
        body += " /AP << /N \(drawingNumber) 0 R >>"
        if let note = addition.note, !note.isEmpty { body += " /Contents \(textString(note))" }
        body += " /P \(pageNumber) \(pageGeneration) R >>"
        return body
    }

    private static func zeroPadded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func dateStamp() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let offset = TimeZone.current.secondsFromGMT(for: now)
        let sign = offset < 0 ? "-" : "+"
        return "D:\(formatter.string(from: now))\(sign)" + String(format: "%02d'%02d'", abs(offset) / 3600, abs(offset) % 3600 / 60)
    }
}
