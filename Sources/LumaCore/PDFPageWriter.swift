import Foundation

/// One page of the document as it is to be once saved: where the page comes from, and how far it
/// is turned when shown.
public struct PageSlot: Equatable {
    public enum Source: Equatable {
        /// A page of the file being saved, by its place in that file's page order.
        case original(Int)
        /// A page of another PDF: which of the documents given to insert from, and the page's place there.
        case inserted(source: Int, page: Int)
    }

    public var source: Source
    /// Degrees, clockwise: 0, 90, 180 or 270.
    public var rotation: Int

    public init(_ source: Source, rotation: Int) {
        self.source = source
        self.rotation = rotation
    }
}

/// Saves page edits — turning, removing, reordering, inserting pages — by appending to the original
/// file, as `PDFAppendWriter` does for annotations: every byte already in the file stays as it is.
///
/// - Turning writes a new version of the page with its new turn and nothing else changed.
/// - Removing and reordering write a new version of the page tree's root listing the pages in their
///   new order. Pages that sat in a lower branch are re-hung from the root, and what they took from
///   that branch (resources, size, turn) is written onto the page itself. A removed page is no
///   longer listed, but stays in the file. Outline entries, links and the opening view that lead to a
///   removed page are made to lead nowhere.
/// - Inserting copies, byte for byte under new numbers, every object the inserted page uses
///   (contents, fonts, images), and lists the page. Links within the other document, form fields
///   and the other document's structure information are left behind; web links and marks come along.
public enum PDFPageWriter {

    /// Why pages could not be inserted from this file, or nil if they can. A file that needs a
    /// password, whose structure is not strictly sound, or whose pages could not be copied (layers,
    /// too many objects) is not copied from. Found out by copying every page once, into memory that
    /// is then let go: so that the reader is told when dropping the file in, not when saving.
    public static func reasonPagesCannotBeInserted(from source: Data) -> PDFAppendError? {
        do {
            let structure = try PDFStructure([UInt8](source))
            if structure.trailer["Encrypt"] != nil { return .refused("the document to insert from is password-protected") }
            let pages = try structure.pageNumbers()
            let trial = Update(header: [], firstNumber: 1)
            let copier = try PageCopier(structure, allocate: { try trial.allocate() })
            for page in pages { _ = try copier.claim(page) }
            for page in pages {
                let rotation = try PDFAppendWriter.pageRotation(structure.object(page), in: structure)
                try copier.writePage(page, rotation: rotation, parent: "1 0 R", into: trial)
            }
            try copier.writePending(into: trial)
            return nil
        } catch let error as PDFAppendError {
            return error
        } catch {
            return .damaged("\(error)")
        }
    }

    /// The turn of each page as the writer sees it (degrees, as shown), in page order.
    public static func rotations(of original: Data) throws -> [Int] {
        let structure = try PDFStructure([UInt8](original))
        return try structure.pageNumbers().map { try PDFAppendWriter.pageRotation(structure.object($0), in: structure) }
    }

    /// Returns the original bytes followed by an update that makes the document consist of `slots`,
    /// in that order. `sources` are the documents pages are inserted from. When the slots describe
    /// the document as it already is, the original is returned untouched.
    public static func applying(_ slots: [PageSlot], sources: [Data] = [], to original: Data) throws -> Data {
        try applying(slots, sources: sources, to: original, sizeLimit: PDFStructure.sizeLimit)
    }

    static func applying(_ slots: [PageSlot], sources: [Data], to original: Data, sizeLimit: Int) throws -> Data {
        let bytes = [UInt8](original)
        let structure = try PDFStructure(bytes, sizeLimit: sizeLimit)
        if let reason = try structure.refusalReason() { throw PDFAppendError.refused(reason) }
        let pages = try structure.pageNumbers()
        guard let rootRaw = structure.trailer["Root"]?.raw, let catalogNumber = structure.trailer["Root"]?.reference?.number else {
            throw PDFAppendError.damaged("trailer does not name the document root")
        }
        let catalog = try structure.catalog()
        guard let treeRoot = catalog["Pages"]?.reference?.number else { throw PDFAppendError.damaged("document has no page tree") }

        // What is asked for must make sense before anything is read further.
        guard !slots.isEmpty else { throw PDFAppendError.refused("a document must keep at least one page") }
        var listed = Set<Int>()
        for slot in slots {
            guard [0, 90, 180, 270].contains(slot.rotation) else { throw PDFAppendError.refused("a page can only be turned by quarter turns") }
            switch slot.source {
            case .original(let index):
                guard pages.indices.contains(index) else { throw PDFAppendError.refused("a page to keep does not exist") }
                guard listed.insert(index).inserted else { throw PDFAppendError.refused("the same page is listed twice") }
            case .inserted(let source, _):
                guard sources.indices.contains(source) else { throw PDFAppendError.refused("the document to insert from is missing") }
            }
        }

        var currentRotation: [Int: Int] = [:]
        for number in pages { currentRotation[number] = try PDFAppendWriter.pageRotation(structure.object(number), in: structure) }
        let keptOrder = slots.compactMap { slot -> Int? in if case .original(let index) = slot.source { return index }; return nil }
        let treeChanges = keptOrder != Array(pages.indices) || slots.count != pages.count
        let turned = slots.contains { slot in
            if case .original(let index) = slot.source { return currentRotation[pages[index]] != slot.rotation }
            return false
        }
        guard treeChanges || turned else { return original }

        let rootNode = try structure.object(treeRoot)
        if treeChanges {
            guard rootNode["Kids"] != nil, rootNode.entries != nil else { throw PDFAppendError.refused("the page tree has no branch to list pages in") }
        }
        try checkParents(structure)
        let listingParent = try structure.listingParents()
        let rootGeneration = structure.entries[treeRoot]?.generation ?? 0
        let deleted = Set(pages).subtracting(keptOrder.map { pages[$0] })

        // The turn a page would take from the root, once hung from it.
        let rootRotation = try PDFAppendWriter.pageRotation(rootNode, in: structure)

        let update = Update(structure: structure)

        // Pages from other documents. A page inserted twice is copied twice; its fonts and images
        // are shared within one round of copying, so a second round only starts for a repeat.
        var copiers: [[PageCopier]] = []
        var sourceStructures: [PDFStructure] = []
        for data in sources {
            let source = try PDFStructure([UInt8](data))
            if source.trailer["Encrypt"] != nil { throw PDFAppendError.refused("the document to insert from is password-protected") }
            _ = try source.pageNumbers()
            sourceStructures.append(source)
            copiers.append([])
        }
        var finalNumbers: [(number: Int, generation: Int)] = []
        var insertedPlaces: [(slot: Int, copier: PageCopier, sourcePage: Int)] = []
        for (position, slot) in slots.enumerated() {
            switch slot.source {
            case .original(let index):
                let number = pages[index]
                finalNumbers.append((number, structure.entries[number]?.generation ?? 0))
            case .inserted(let source, let page):
                let sourcePages = try sourceStructures[source].pageNumbers()
                guard sourcePages.indices.contains(page) else { throw PDFAppendError.refused("a page to insert does not exist") }
                let sourcePage = sourcePages[page]
                var copier = copiers[source].first { !$0.claims(sourcePage) }
                if copier == nil {
                    copier = try PageCopier(sourceStructures[source], allocate: { try update.allocate() })
                    copiers[source].append(copier!)
                }
                let number = try copier!.claim(sourcePage)
                finalNumbers.append((number, 0))
                insertedPlaces.append((position, copier!, sourcePage))
            }
        }

        // Outline entries, links and the opening view that would lead to a removed page.
        let fixes = deleted.isEmpty ? Fixes() : try Fixes.find(in: structure, catalog: catalog, pages: keptOrder.map { pages[$0] }, leadingTo: deleted)

        // Inserted pages and everything they use.
        for place in insertedPlaces {
            try place.copier.writePage(place.sourcePage, rotation: slots[place.slot].rotation,
                                       parent: "\(treeRoot) \(rootGeneration) R", into: update)
        }
        for round in copiers.joined() { try round.writePending(into: update) }
        try checkObjectNumbers(update)

        // Pages of this file that change: a new turn, a new place in the tree, or a link to fix.
        for slot in slots {
            guard case .original(let index) = slot.source else { continue }
            let number = pages[index]
            let page = try structure.object(number)
            guard let entries = page.entries else { throw PDFAppendError.damaged("page is not a dictionary") }
            guard Set(entries.map(\.key)).count == entries.count else { throw PDFAppendError.damaged("page lists the same property twice") }
            let rehang = treeChanges && (listingParent[number] != treeRoot || page["Parent"]?.reference?.number != treeRoot)
            let current = currentRotation[number] ?? 0
            let ownTurn = try own("Rotate", of: page, in: structure) != nil
            let inheritedAfter = rehang ? rootRotation : current
            let writeTurn: Bool
            if ownTurn { writeTurn = slot.rotation != current } else { writeTurn = slot.rotation != inheritedAfter }
            let listFix = fixes.inlineLinks[number]
            guard rehang || writeTurn || listFix != nil else { continue }

            try update.begin(number, generation: structure.entries[number]?.generation ?? 0)
            update.emit("<<")
            for entry in entries {
                if rehang && entry.key == "Parent" { continue }
                // A null resource, size or crop is written afresh below with what the page inherits.
                if rehang && ["Resources", "MediaBox", "CropBox"].contains(entry.key), try own(entry.key, of: page, in: structure) == nil { continue }
                if writeTurn && entry.key == "Rotate" { continue }
                if listFix != nil && entry.key == "Annots" { continue }
                update.emit(" ")
                update.out.append(contentsOf: entry.rawKey)
                update.emit(" ")
                update.out.append(contentsOf: entry.value.raw)
            }
            if rehang {
                update.emit(" /Parent \(treeRoot) \(rootGeneration) R")
                // What the page took from a lower branch is now its own; what it took from the root it still takes.
                for key in ["Resources", "MediaBox", "CropBox"] where try own(key, of: page, in: structure) == nil {
                    guard let found = try inherited(key, from: page, in: structure), found.holder != treeRoot else { continue }
                    update.emit(" /\(key) ")
                    update.out.append(contentsOf: found.value.raw)
                }
            }
            if writeTurn { update.emit(" /Rotate \(slot.rotation)") }
            if let listFix {
                update.emit(" /Annots ")
                update.out.append(contentsOf: listFix)
            }
            update.emit(" >>\nendobj\n")
        }

        // The tree's root, listing every page in its new order.
        if treeChanges {
            guard let entries = rootNode.entries else { throw PDFAppendError.damaged("page tree is not a dictionary") }
            try update.begin(treeRoot, generation: rootGeneration)
            update.emit("<<")
            for entry in entries where entry.key != "Kids" && entry.key != "Count" {
                update.emit(" ")
                update.out.append(contentsOf: entry.rawKey)
                update.emit(" ")
                update.out.append(contentsOf: entry.value.raw)
            }
            update.emit(" /Kids [\(finalNumbers.map { "\($0.number) \($0.generation) R" }.joined(separator: " "))] /Count \(slots.count) >>\nendobj\n")
        }

        // Objects that lead to a removed page, written again without the way there.
        for (number, body) in fixes.objects.sorted(by: { $0.key < $1.key }) {
            try update.begin(number, generation: structure.entries[number]?.generation ?? 0)
            update.out.append(contentsOf: body)
            update.emit("\nendobj\n")
        }
        // A publisher's usage-rights seal is signed over the file as it was; after a page edit it no
        // longer holds, and Adobe's reader would say so each time. It goes, and the form no longer says
        // that signatures exist or that the file may only be appended to. (The file was not refused,
        // so /Perms holds nothing but such a seal.)
        let retiringSeal = catalog["Perms"] != nil
        var formBody: [UInt8]?
        if retiringSeal, let form = catalog["AcroForm"], let fields = try structure.resolve(form).entries {
            var body = Array("<<".utf8)
            for field in fields {
                body.append(32)
                body.append(contentsOf: field.rawKey)
                body.append(32)
                if field.key == "SigFlags" {
                    body.append(contentsOf: Array("\((try structure.resolve(field.value).int ?? 0) & ~3)".utf8))
                } else {
                    body.append(contentsOf: field.value.raw)
                }
            }
            body.append(contentsOf: Array(" >>".utf8))
            formBody = body
        }
        if fixes.catalogLeadsToRemovedPage || retiringSeal, let entries = catalog.entries {
            try update.begin(catalogNumber, generation: structure.entries[catalogNumber]?.generation ?? 0)
            update.emit("<<")
            for entry in entries {
                if fixes.catalogLeadsToRemovedPage && entry.key == "OpenAction" { continue }
                if retiringSeal && entry.key == "Perms" { continue }
                update.emit(" ")
                update.out.append(contentsOf: entry.rawKey)
                update.emit(" ")
                if entry.key == "AcroForm", entry.value.reference == nil, let formBody {
                    update.out.append(contentsOf: formBody)
                } else {
                    update.out.append(contentsOf: entry.value.raw)
                }
            }
            update.emit(" >>\nendobj\n")
        }
        if let form = catalog["AcroForm"]?.reference, let formBody {
            try update.begin(form.number, generation: structure.entries[form.number]?.generation ?? 0)
            update.out.append(contentsOf: formBody)
            update.emit("\nendobj\n")
        }

        try checkObjectNumbers(update)
        PDFAppendWriter.appendIndex(to: &update.out, written: update.written, nextNumber: update.nextNumber, structure: structure, rootRaw: rootRaw)
        guard update.out.count < sizeLimit else { throw PDFAppendError.refused("file would grow past 4 GB") }

        try selfCheck(update.out, original: structure, slots: slots, finalNumbers: finalNumbers.map(\.number), pages: pages,
                      inserted: insertedPlaces.map { ($0.slot, $0.copier, $0.sourcePage) }, copiers: Array(copiers.joined()), deleted: deleted)
        return Data(update.out)
    }

    private static func checkObjectNumbers(_ update: Update) throws {
        // One more number is needed for a compressed index.
        guard update.nextNumber + 1 <= PDFStructure.maximumObjectNumber else { throw PDFAppendError.refused("file has no object numbers left") }
    }

    /// A value a page takes from the page tree above it, following its /Parent as readers do, and
    /// the number of the node that holds it (nil for the page itself).
    static func inherited(_ key: String, from page: PDFValue, in structure: PDFStructure) throws -> (value: PDFValue, holder: Int?)? {
        var node = page
        var holder: Int?
        for _ in 0..<32 {
            // A value written as null counts as not written: readers go on up the tree for it.
            if let value = node[key], !(try structure.resolve(value)).isNull { return (value, holder) }
            guard let parent = node["Parent"], let reference = parent.reference else { return nil }
            holder = reference.number
            node = try structure.resolve(parent)
        }
        return nil
    }

    /// A page's own value for a key, or nil when it has none or writes null (which readers take as none).
    static func own(_ key: String, of page: PDFValue, in structure: PDFStructure) throws -> PDFValue? {
        guard let value = page[key], !(try structure.resolve(value)).isNull else { return nil }
        return value
    }

    /// Every page must name as its parent the branch that lists it. Where the two disagree, readers
    /// take inherited resources, size and turn from different places, so a page edit could change
    /// what some of them show.
    /// The same holds for every branch below the root: readers follow /Parent up from a page.
    static func checkParents(_ structure: PDFStructure) throws {
        _ = try structure.pageNumbers()   // the tree is sound: no loops, every branch counted
        guard let root = try structure.catalog()["Pages"] else { return }
        func walk(_ reference: PDFValue, listedBy parent: Int?) throws {
            guard let number = reference.reference?.number else { return }
            let node = try structure.resolve(reference)
            // The root has no parent: one it names would be where readers look for what it inherits.
            if parent == nil ? node["Parent"] != nil : node["Parent"]?.reference?.number != parent {
                throw PDFAppendError.refused("a page names another branch of the page tree than the one that lists it")
            }
            guard let kids = node["Kids"] else { return }
            for kid in try structure.resolve(kids).array ?? [] { try walk(kid, listedBy: number) }
        }
        try walk(root, listedBy: nil)
    }

    // MARK: Writing

    /// An update being written after the original bytes: what has been written, and where.
    final class Update {
        var out: [UInt8]
        var written: [(number: Int, generation: Int, offset: Int)] = []
        var nextNumber: Int
        private var begun = Set<Int>()

        init(structure: PDFStructure) {
            out = structure.bytes
            if let last = out.last, last != 10 && last != 13 { out.append(10) }
            // The index reader has already made sure the declared size is a sane number.
            nextNumber = max(structure.trailer["Size"]?.int ?? 0, (structure.entries.keys.max() ?? 0) + 1)
        }

        /// A new file, starting with `header`, its objects numbered from `firstNumber`.
        init(header: [UInt8], firstNumber: Int) {
            out = header
            nextNumber = firstNumber
        }

        func emit(_ text: String) { out.append(contentsOf: Array(text.utf8)) }

        func allocate() throws -> Int {
            guard nextNumber + 1 < PDFStructure.maximumObjectNumber else { throw PDFAppendError.refused("file has no object numbers left") }
            defer { nextNumber += 1 }
            return nextNumber
        }

        /// Starts a new version of an object. Each object is written at most once in an update.
        func begin(_ number: Int, generation: Int) throws {
            guard begun.insert(number).inserted else { throw PDFAppendError.selfCheckFailed("an object was written twice in one update") }
            written.append((number, generation, out.count))
            emit("\(number) \(generation) obj\n")
        }
    }

    // MARK: Copying pages from another document

    /// Copies pages of one document, and every object they use, under new numbers. One copier is
    /// one round: each of its pages is copied once, and what they share is copied once.
    final class PageCopier {
        let source: PDFStructure
        private let sourcePages: Set<Int>
        private let allocate: () throws -> Int
        /// Source number → new number, for every object copied or about to be.
        private(set) var map: [Int: Int] = [:]
        /// Pages of this round: source number → new number.
        private(set) var pages: [Int: Int] = [:]
        /// Annotations left behind on the copied pages, by source number.
        private(set) var leftBehind = Set<Int>()
        private var pending: [Int] = []
        private var pendingIndex = 0
        /// Objects that are copied into the page itself instead of as objects (the page's own dictionary).
        private var copiedCount = 0

        /// What is copied: pages to insert into another document, which leave behind what belongs to
        /// their own document (links within it, form fields, its outline, layers are refused); or a whole
        /// document into a new file, which keeps everything but the page tree and the structure
        /// information (the accessibility tags, which name pages and places in them).
        enum Mode {
            case insert
            case wholeDocument
        }

        let mode: Mode

        /// Kinds of object that belong to the other document as a whole, not to a page. A reference
        /// to one is written as null.
        private var documentLevel: Set<String> {
            switch mode {
            case .insert: return ["Catalog", "Pages", "StructTreeRoot", "StructElem", "Outlines", "MCR", "OBJR"]
            case .wholeDocument: return ["Catalog", "Pages", "StructTreeRoot", "StructElem", "MCR", "OBJR"]
            }
        }

        init(_ source: PDFStructure, mode: Mode = .insert, allocate: @escaping () throws -> Int) throws {
            self.source = source
            self.mode = mode
            sourcePages = Set(try source.pageNumbers())
            try PDFPageWriter.checkParents(source)
            self.allocate = allocate
        }

        func claims(_ sourcePage: Int) -> Bool { pages[sourcePage] != nil }

        func claim(_ sourcePage: Int) throws -> Int {
            let number = try allocate()
            pages[sourcePage] = number
            map[sourcePage] = number
            return number
        }

        /// The new number for a source object, copying it later if this is the first time it is met.
        /// Nil when it is not copied: freed or missing, another page, or part of the document as a whole.
        func reference(_ number: Int, _ generation: Int) throws -> Int? {
            if let mapped = map[number] { return mapped }
            if let entry = source.entries[number], entry.isLive, entry.generation != generation {
                throw PDFAppendError.damaged("a reference names an outdated version of an object")
            }
            if sourcePages.contains(number) { return nil }
            let value = try source.object(number)
            if value.isNull { return nil }
            if let type = value["Type"]?.name {
                if documentLevel.contains(type) || type == "Page" { return nil }
                if mode == .insert && (type == "OCG" || type == "OCMD") {
                    throw PDFAppendError.refused("the pages to insert use layers, which cannot be carried over")
                }
            }
            copiedCount += 1
            guard copiedCount <= 1_000_000 else { throw PDFAppendError.refused("the pages to insert use too many objects") }
            let mapped = try allocate()
            map[number] = mapped
            pending.append(number)
            return mapped
        }

        /// Writes a value with every reference renumbered. Everything else is copied as it is written.
        func write(_ value: PDFValue, into out: inout [UInt8]) throws {
            switch value.node {
            case .ref(let number, let generation):
                if let mapped = try reference(number, generation) {
                    out.append(contentsOf: Array("\(mapped) 0 R".utf8))
                } else {
                    out.append(contentsOf: Array("null".utf8))
                }
            case .array(let items):
                out.append(0x5B)
                for (k, item) in items.enumerated() {
                    if k > 0 { out.append(32) }
                    try write(item, into: &out)
                }
                out.append(0x5D)
            case .dict(let entries):
                out.append(contentsOf: Array("<<".utf8))
                for entry in entries {
                    out.append(32)
                    out.append(contentsOf: entry.rawKey)
                    out.append(32)
                    try write(entry.value, into: &out)
                }
                out.append(contentsOf: Array(" >>".utf8))
            default:
                out.append(contentsOf: value.raw)
            }
        }

        /// Whether an annotation stays behind: links within the other document, form fields, and
        /// pop-ups of annotations that stay behind.
        private func staysBehind(_ annotation: PDFValue) throws -> Bool {
            guard mode == .insert else { return false }
            switch annotation["Subtype"]?.name {
            case "Widget":
                return true
            case "Link":
                if annotation["Dest"] != nil { return true }
                if let action = annotation["A"], try source.resolve(action)["S"]?.name == "GoTo" { return true }
                return false
            default:
                return false
            }
        }

        /// Writes the new page: its own entries, what it took from the other document's page tree,
        /// its turn, and the annotations that come along.
        func writePage(_ sourcePage: Int, rotation: Int, parent: String, into update: Update) throws {
            guard let number = pages[sourcePage] else { preconditionFailure("page was not claimed") }
            let page = try source.object(sourcePage)
            guard let entries = page.entries else { throw PDFAppendError.damaged("page to insert is not a dictionary") }
            guard Set(entries.map(\.key)).count == entries.count else { throw PDFAppendError.damaged("page to insert lists the same property twice") }

            // Annotations: those that come along keep their place in the list.
            var kept: [PDFValue] = []
            if let list = page["Annots"] {
                let resolved = try source.resolve(list)
                if let items = resolved.array {
                    var behind = Set<Int>()
                    var values: [(item: PDFValue, value: PDFValue)] = []
                    for item in items {
                        let value = try source.resolve(item)
                        guard value.entries != nil else { continue }
                        values.append((item, value))
                        if try staysBehind(value), let reference = item.reference { behind.insert(reference.number) }
                    }
                    for (item, value) in values {
                        if try staysBehind(value) { continue }
                        // A pop-up goes only with the annotation it belongs to.
                        if value["Subtype"]?.name == "Popup", let owner = value["Parent"]?.reference, behind.contains(owner.number) {
                            behind.insert(item.reference?.number ?? -1)
                            continue
                        }
                        kept.append(item)
                    }
                    leftBehind.formUnion(behind)
                } else if !resolved.isNull {
                    throw PDFAppendError.damaged("annotation list of the page to insert is not a list")
                }
            }

            var body: [UInt8] = []
            body.append(contentsOf: Array("<<".utf8))
            // A page's own actions (on opening, on closing) stay with a whole document only.
            let notCopied: Set<String> = mode == .insert ? ["Parent", "StructParents", "B", "AA", "Annots", "Rotate"]
                : ["Parent", "StructParents", "B", "Annots", "Rotate"]
            for entry in entries where !notCopied.contains(entry.key) {
                if ["Resources", "MediaBox", "CropBox"].contains(entry.key), try PDFPageWriter.own(entry.key, of: page, in: source) == nil { continue }
                body.append(32)
                body.append(contentsOf: entry.rawKey)
                body.append(32)
                try write(entry.value, into: &body)
            }
            if page["Type"] == nil { body.append(contentsOf: Array(" /Type /Page".utf8)) }
            body.append(contentsOf: Array(" /Parent \(parent)".utf8))
            for key in ["Resources", "MediaBox", "CropBox"] where try PDFPageWriter.own(key, of: page, in: source) == nil {
                guard let found = try PDFPageWriter.inherited(key, from: page, in: source) else { continue }
                body.append(contentsOf: Array(" /\(key) ".utf8))
                try write(found.value, into: &body)
            }
            body.append(contentsOf: Array(" /Rotate \(rotation)".utf8))
            if !kept.isEmpty {
                body.append(contentsOf: Array(" /Annots [".utf8))
                for item in kept {
                    body.append(32)
                    try write(item, into: &body)
                }
                body.append(contentsOf: Array(" ]".utf8))
            }
            body.append(contentsOf: Array(" >>".utf8))

            try update.begin(number, generation: 0)
            update.out.append(contentsOf: body)
            update.emit("\nendobj\n")
        }

        /// Writes every object met so far, and those they lead to, until none is left.
        func writePending(into update: Update) throws {
            while pendingIndex < pending.count {
                let number = pending[pendingIndex]
                pendingIndex += 1
                guard let mapped = map[number] else { continue }
                var body: [UInt8] = []
                if let stream = try source.storedStream(number) {
                    guard let entries = stream.dictionary.entries else { throw PDFAppendError.damaged("data stream has no dictionary") }
                    body.append(contentsOf: Array("<<".utf8))
                    for entry in entries where entry.key != "Length" {
                        body.append(32)
                        body.append(contentsOf: entry.rawKey)
                        body.append(32)
                        try write(entry.value, into: &body)
                    }
                    body.append(contentsOf: Array(" /Length \(stream.data.count) >>\nstream\n".utf8))
                    body.append(contentsOf: stream.data)
                    body.append(contentsOf: Array("\nendstream".utf8))
                } else {
                    try write(try source.object(number), into: &body)
                }
                try update.begin(mapped, generation: 0)
                update.out.append(contentsOf: body)
                update.emit("\nendobj\n")
            }
        }
    }

    // MARK: Ways to a removed page

    /// Objects to write again so that nothing leads to a removed page: outline entries and links
    /// lose their destination (they stay, leading nowhere), and the catalog loses an opening view
    /// on a removed page.
    struct Fixes {
        /// New bodies of whole objects (outline entries, links, annotation lists), by number.
        var objects: [Int: [UInt8]] = [:]
        /// New annotation lists for pages whose links are written straight into the page's list.
        var inlineLinks: [Int: [UInt8]] = [:]
        var catalogLeadsToRemovedPage = false

        var isEmpty: Bool { objects.isEmpty && inlineLinks.isEmpty && !catalogLeadsToRemovedPage }

        static func find(in structure: PDFStructure, catalog: PDFValue, pages: [Int], leadingTo removed: Set<Int>) throws -> Fixes {
            var fixes = Fixes()
            let names = try NamedDestinations(structure, catalog: catalog)
            func leadsToRemoved(_ value: PDFValue) throws -> Bool {
                guard let target = try names.page(of: value, in: structure) else { return false }
                return removed.contains(target)
            }
            /// An outline entry or link with its destination taken out: /Dest, and /A when it is a "go to".
            func withoutWay(_ value: PDFValue) throws -> [UInt8]? {
                var leads = false
                var drop: Set<String> = []
                if let dest = value["Dest"], try leadsToRemoved(dest) { leads = true; drop.insert("Dest") }
                if let actionValue = value["A"] {
                    let action = try structure.resolve(actionValue)
                    if action["S"]?.name == "GoTo", let d = action["D"], try leadsToRemoved(d) { leads = true; drop.insert("A") }
                }
                guard leads, let entries = value.entries else { return nil }
                var body = Array("<<".utf8)
                for entry in entries where !drop.contains(entry.key) {
                    body.append(32)
                    body.append(contentsOf: entry.rawKey)
                    body.append(32)
                    body.append(contentsOf: entry.value.raw)
                }
                body.append(contentsOf: Array(" >>".utf8))
                return body
            }

            // Outline entries, walked by First and Next.
            if let outlines = catalog["Outlines"] {
                var visited = Set<Int>()
                var stack: [PDFValue] = []
                if let first = try structure.resolve(outlines)["First"] { stack.append(first) }
                while let next = stack.popLast() {
                    guard let number = next.reference?.number, visited.insert(number).inserted else { continue }
                    guard visited.count <= 200_000 else { throw PDFAppendError.damaged("outline has too many entries to check") }
                    let item = try structure.resolve(next)
                    guard item.entries != nil else { continue }
                    if let body = try withoutWay(item) { fixes.objects[number] = body }
                    if let sibling = item["Next"] { stack.append(sibling) }
                    if let child = item["First"] { stack.append(child) }
                }
            }

            // Links on the pages that stay.
            for page in pages {
                let value = try structure.object(page)
                guard let list = value["Annots"] else { continue }
                let resolved = try structure.resolve(list)
                guard let items = resolved.array else { continue }
                var inline: [Int: [UInt8]] = [:]
                for (place, item) in items.enumerated() {
                    let annotation = try structure.resolve(item)
                    guard annotation["Subtype"]?.name == "Link", let body = try withoutWay(annotation) else { continue }
                    if let number = item.reference?.number {
                        fixes.objects[number] = body
                    } else {
                        inline[place] = body
                    }
                }
                guard !inline.isEmpty else { continue }
                var body = Array("[".utf8)
                for (place, item) in items.enumerated() {
                    body.append(32)
                    body.append(contentsOf: inline[place] ?? Array(item.raw))
                }
                body.append(contentsOf: Array(" ]".utf8))
                if let number = list.reference?.number {
                    // The list is an object of its own: that object is written again.
                    fixes.objects[number] = body
                } else {
                    fixes.inlineLinks[page] = body
                }
            }

            // The view the document opens at.
            if let open = catalog["OpenAction"] {
                let value = try structure.resolve(open)
                if value.array != nil {
                    fixes.catalogLeadsToRemovedPage = try leadsToRemoved(value)
                } else if value["S"]?.name == "GoTo", let d = value["D"] {
                    fixes.catalogLeadsToRemovedPage = try leadsToRemoved(d)
                }
            }
            return fixes
        }
    }

    /// The document's named destinations, from the old dictionary (/Dests) and the name tree
    /// (/Names /Dests), read once.
    struct NamedDestinations {
        private var byName: [String: PDFValue] = [:]
        private var byString: [[UInt8]: PDFValue] = [:]

        init(_ structure: PDFStructure, catalog: PDFValue) throws {
            if let dests = catalog["Dests"], let entries = try structure.resolve(dests).entries {
                for entry in entries { byName[entry.key] = entry.value }
            }
            guard let names = catalog["Names"], let tree = try structure.resolve(names)["Dests"] else { return }
            var visited = Set<Int>()
            var count = 0
            var found: [[UInt8]: PDFValue] = [:]
            defer { byString = found }
            func walk(_ node: PDFValue, depth: Int) throws {
                guard depth < 32 else { throw PDFAppendError.damaged("named destinations are nested too deeply") }
                if let number = node.reference?.number { guard visited.insert(number).inserted else { return } }
                let value = try structure.resolve(node)
                if let list = try value["Names"].map({ try structure.resolve($0) })?.array {
                    var k = 0
                    while k + 1 < list.count {
                        if let key = PDFStrings.bytes(list[k].raw) { found[key] = list[k + 1] }
                        k += 2
                        count += 1
                        guard count <= 500_000 else { throw PDFAppendError.damaged("too many named destinations to check") }
                    }
                }
                if let kids = try value["Kids"].map({ try structure.resolve($0) })?.array {
                    for kid in kids { try walk(kid, depth: depth + 1) }
                }
            }
            try walk(tree, depth: 0)
        }

        /// The page object a destination leads to: an explicit one, a name, or a dictionary holding /D.
        func page(of destination: PDFValue, in structure: PDFStructure, depth: Int = 0) throws -> Int? {
            guard depth < 4 else { return nil }
            let value = try structure.resolve(destination)
            if let list = value.array { return list.first?.reference?.number }
            if let name = value.name, let found = byName[name] { return try page(of: found, in: structure, depth: depth + 1) }
            if case .string = value.node, let key = PDFStrings.bytes(value.raw) {
                if let found = byString[key] { return try page(of: found, in: structure, depth: depth + 1) }
                if let found = byName[String(decoding: key, as: UTF8.self)] { return try page(of: found, in: structure, depth: depth + 1) }
                return nil
            }
            if let name = value.name, let found = byString[Array(name.utf8)] { return try page(of: found, in: structure, depth: depth + 1) }
            if let d = value["D"] { return try page(of: d, in: structure, depth: depth + 1) }
            return nil
        }
    }

    // MARK: Checking

    /// Reads the result back with the strict reader before anyone else sees it.
    static func selfCheck(_ out: [UInt8], original: PDFStructure, slots: [PageSlot], finalNumbers: [Int], pages: [Int],
                          inserted: [(slot: Int, copier: PageCopier, sourcePage: Int)], copiers: [PageCopier], deleted: Set<Int>) throws {
        do {
            let bytes = original.bytes
            let preserved = out.count > bytes.count && out.withUnsafeBytes { o in bytes.withUnsafeBytes { memcmp(o.baseAddress!, $0.baseAddress!, $0.count) == 0 } }
            guard preserved else { throw PDFAppendError.selfCheckFailed("original bytes were not preserved") }
            let result = try PDFStructure(out)
            guard try result.pageNumbers() == finalNumbers else { throw PDFAppendError.selfCheckFailed("pages are not in the order asked for") }
            if let reason = try result.refusalReason() { throw PDFAppendError.selfCheckFailed("result would be refused: \(reason)") }
            guard try result.catalog()["Perms"] == nil else { throw PDFAppendError.selfCheckFailed("the usage-rights seal is still there") }

            for (position, number) in finalNumbers.enumerated() {
                let page = try result.object(number)
                guard try PDFAppendWriter.pageRotation(page, in: result) == slots[position].rotation else {
                    throw PDFAppendError.selfCheckFailed("page \(position + 1) is not turned as asked")
                }
                guard case .original = slots[position].source else { continue }
                // A page of this file must show exactly what it showed: the same contents, resources and size.
                let before = try original.object(number)
                for key in ["Contents", "Resources", "MediaBox", "CropBox"] {
                    let was = try inherited(key, from: before, in: original).map { Array($0.value.raw) }
                    let now = try inherited(key, from: page, in: result).map { Array($0.value.raw) }
                    guard was == now else { throw PDFAppendError.selfCheckFailed("page \(position + 1) no longer shows what it showed (\(key))") }
                }
                // Its annotations all stay; a link may only have lost its destination.
                let was = try before["Annots"].map { try original.resolve($0).array?.count ?? -1 } ?? 0
                let now = try page["Annots"].map { try result.resolve($0).array?.count ?? -1 } ?? 0
                guard was == now else { throw PDFAppendError.selfCheckFailed("page \(position + 1) lost annotations") }
            }

            // Every copied object must read back as the original did, renumbered.
            for copier in copiers {
                for (old, new) in copier.map where copier.pages[old] == nil {
                    guard try same(result.object(new), copier.source.object(old), copier: copier, result: result) else {
                        throw PDFAppendError.selfCheckFailed("a copied object does not read back")
                    }
                    let a = try result.storedStream(new), b = try copier.source.storedStream(old)
                    guard (a == nil) == (b == nil), a.map({ Array($0.data) }) == b.map({ Array($0.data) }) else {
                        throw PDFAppendError.selfCheckFailed("a copied data stream does not read back")
                    }
                }
            }
            for place in inserted {
                let page = try result.object(finalNumbers[place.slot])
                let before = try place.copier.source.object(place.sourcePage)
                for key in ["Contents", "Resources", "MediaBox", "CropBox"] {
                    let was = try inherited(key, from: before, in: place.copier.source)?.value
                    let now = try inherited(key, from: page, in: result)?.value
                    guard (was == nil) == (now == nil) else { throw PDFAppendError.selfCheckFailed("inserted page lost \(key)") }
                    if let was, let now { guard try same(now, was, copier: place.copier, result: result) else {
                        throw PDFAppendError.selfCheckFailed("inserted page does not show what it showed (\(key))")
                    } }
                }
            }

            // Nothing may lead to a removed page any more.
            if !deleted.isEmpty {
                let originals = Set(pages)
                let found = try Fixes.find(in: result, catalog: try result.catalog(), pages: finalNumbers.filter(originals.contains), leadingTo: deleted)
                guard found.isEmpty else { throw PDFAppendError.selfCheckFailed("something still leads to a removed page") }
            }
        } catch let error as PDFAppendError {
            if case .selfCheckFailed = error { throw error }
            throw PDFAppendError.selfCheckFailed(error.description)
        }
    }

    /// Whether a value in the result is the source's value with its references renumbered.
    static func same(_ now: PDFValue, _ was: PDFValue, copier: PageCopier, result: PDFStructure, depth: Int = 0) throws -> Bool {
        guard depth < 70 else { return false }
        switch (now.node, was.node) {
        case (.ref(let n, _), .ref(let w, _)):
            return copier.map[w] == n
        case (.null, .ref(let w, _)):
            return copier.map[w] == nil
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where !(try same(x, y, copier: copier, result: result, depth: depth + 1)) { return false }
            return true
        case (.dict(let a), .dict(let b)):
            let keptB = b.filter { $0.key != "Length" }
            let keptA = a.filter { $0.key != "Length" }
            guard keptA.count == keptB.count else { return false }
            for (x, y) in zip(keptA, keptB) {
                guard x.key == y.key, try same(x.value, y.value, copier: copier, result: result, depth: depth + 1) else { return false }
            }
            return true
        default:
            return Array(now.raw) == Array(was.raw)
        }
    }
}

extension PDFStructure {
    /// For every page, the page tree node whose /Kids lists it.
    func listingParents() throws -> [Int: Int] {
        _ = try pageNumbers()   // the tree is sound: no loops, every branch counted
        guard let root = try catalog()["Pages"] else { return [:] }
        var parents: [Int: Int] = [:]
        func walk(_ reference: PDFValue, parent: Int?) throws {
            guard let number = reference.reference?.number else { return }
            let node = try resolve(reference)
            if let kids = node["Kids"] {
                for kid in try resolve(kids).array ?? [] { try walk(kid, parent: number) }
            } else if let parent {
                parents[number] = parent
            }
        }
        try walk(root, parent: nil)
        return parents
    }
}

/// Reading the bytes of PDF strings, for comparing names of destinations.
enum PDFStrings {
    /// The bytes a literal "( … )" or hexadecimal "< … >" string stands for; nil if it is neither.
    static func bytes(_ raw: ArraySlice<UInt8>) -> [UInt8]? {
        guard let first = raw.first else { return nil }
        if first == 0x3C {
            var digits: [UInt8] = []
            for c in raw.dropFirst() {
                if c == 0x3E { break }
                if PDFParser.isSpace(c) { continue }
                digits.append(c)
            }
            if digits.count % 2 == 1 { digits.append(0x30) }
            var out: [UInt8] = []
            var k = 0
            while k < digits.count {
                guard let high = hex(digits[k]), let low = hex(digits[k + 1]) else { return nil }
                out.append(high << 4 | low)
                k += 2
            }
            return out
        }
        guard first == 0x28 else { return nil }
        let body = Array(raw.dropFirst().dropLast())
        var out: [UInt8] = []
        var k = 0
        while k < body.count {
            let c = body[k]
            if c == 0x5C, k + 1 < body.count {
                let e = body[k + 1]
                k += 2
                switch e {
                case 0x6E: out.append(10)
                case 0x72: out.append(13)
                case 0x74: out.append(9)
                case 0x62: out.append(8)
                case 0x66: out.append(12)
                case 0x0D:
                    if k < body.count && body[k] == 0x0A { k += 1 }
                case 0x0A: break
                case 0x30...0x37:
                    var value = Int(e - 0x30)
                    var n = 1
                    while n < 3, k < body.count, (0x30...0x37).contains(body[k]) {
                        value = value * 8 + Int(body[k] - 0x30)
                        k += 1
                        n += 1
                    }
                    out.append(UInt8(value & 0xFF))
                default: out.append(e)
                }
                continue
            }
            if c == 0x0D {
                // A line end inside a string reads as a single line feed.
                out.append(10)
                k += 1
                if k < body.count && body[k] == 0x0A { k += 1 }
                continue
            }
            out.append(c)
            k += 1
        }
        return out
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}
