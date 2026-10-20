import AppKit
import LumaCore
import PDFKit

/// The reader's page edits in one document — turning, taking out, moving and inserting pages — made
/// on the system engine's pages at once, so that they show, and kept as the list of pages saving has
/// to write. Until saved they are unsaved changes that can be undone, together with the marks: both
/// use the same undo.
final class PageEditor {
    /// A document pages are inserted from: its file's bytes, which saving copies the pages out of, and
    /// the document read from those same bytes, whose pages are shown.
    struct Source {
        let url: URL
        let data: Data
        let document: PDFDocument
    }

    private unowned let session: DocumentSession
    /// One entry per page now in the document, in order: where it comes from in the file as last
    /// read or saved (or in a source), and its turn.
    private(set) var slots: [PageSlot]
    /// The turns of the file's own pages as last read or saved.
    private var fileRotations: [Int]
    private(set) var sources: [Source] = []
    /// Called after every edit, including undo and redo.
    var onChange: (() -> Void)?

    init(session: DocumentSession) {
        self.session = session
        fileRotations = (0..<session.document.pageCount).map { session.document.page(at: $0)?.rotation ?? 0 }
        slots = fileRotations.enumerated().map { PageSlot(.original($0.offset), rotation: $0.element) }
    }

    private var undoManager: UndoManager { session.markup.undoManager }

    var hasUnsavedChanges: Bool {
        slots != fileRotations.enumerated().map { PageSlot(.original($0.offset), rotation: $0.element) }
    }

    /// What saving writes: the pages in order, and only the sources still used, renumbered.
    var forSaving: (slots: [PageSlot], sources: [Data])? {
        guard hasUnsavedChanges else { return nil }
        var used: [Int: Int] = [:]
        var data: [Data] = []
        let renumbered = slots.map { slot -> PageSlot in
            guard case .inserted(let source, let page) = slot.source else { return slot }
            if used[source] == nil {
                used[source] = data.count
                data.append(sources[source].data)
            }
            return PageSlot(.inserted(source: used[source]!, page: page), rotation: slot.rotation)
        }
        return (renumbered, data)
    }

    /// After a save that wrote the page edits: the document as it is now is what the file holds.
    /// The sources are let go, and nothing is left to write again.
    func didSave() {
        fileRotations = (0..<session.document.pageCount).map { session.document.page(at: $0)?.rotation ?? 0 }
        slots = fileRotations.enumerated().map { PageSlot(.original($0.offset), rotation: $0.element) }
        sources = []
    }

    /// Marks' changes moved back to the page numbers of the file as last read or saved, for putting
    /// them back on a fresh reading of it; and, for each such number, the page the change was made on.
    /// Changes on inserted pages have no place in the file: they are counted, not returned.
    func toFilePages(_ changes: [MarkupChange]) -> (changes: [MarkupChange], pageMadeOn: [Int: PDFPage], onInsertedPages: Int) {
        var moved: [MarkupChange] = []
        var pageMadeOn: [Int: PDFPage] = [:]
        var onInserted = 0
        for change in changes {
            guard slots.indices.contains(change.pageIndex), case .original(let filePage) = slots[change.pageIndex].source else {
                onInserted += 1
                continue
            }
            pageMadeOn[filePage] = session.document.page(at: change.pageIndex)
            switch change {
            case .add(var addition):
                addition.pageIndex = filePage
                moved.append(.add(addition))
            case .modify(_, let original, let colour, let note):
                moved.append(.modify(page: filePage, original: original, colour: colour, note: note))
            case .remove(_, let original):
                moved.append(.remove(page: filePage, original: original))
            }
        }
        return (moved, pageMadeOn, onInserted)
    }

    // MARK: Edits

    private enum Edit {
        case turn(Int, to: Int)
        case takeOut(Range<Int>)
        case putIn([(page: PDFPage, slot: PageSlot)], at: Int)
        case move(from: Int, to: Int)
    }

    /// Makes an edit and returns the one that undoes it.
    private func apply(_ edit: Edit) -> Edit {
        let document = session.document
        switch edit {
        case .turn(let index, let rotation):
            let old = slots[index].rotation
            document.page(at: index)?.rotation = rotation
            slots[index].rotation = rotation
            return .turn(index, to: old)
        case .takeOut(let range):
            var taken: [(page: PDFPage, slot: PageSlot)] = []
            for index in range {
                if let page = document.page(at: index) { taken.append((page, slots[index])) }
            }
            for index in range.reversed() { document.removePage(at: index) }
            slots.removeSubrange(range)
            return .putIn(taken, at: range.lowerBound)
        case .putIn(let pages, let position):
            for (k, item) in pages.enumerated() { document.insert(item.page, at: position + k) }
            slots.insert(contentsOf: pages.map(\.slot), at: position)
            return .takeOut(position..<(position + pages.count))
        case .move(let from, let to):
            if let page = document.page(at: from) {
                document.removePage(at: from)
                document.insert(page, at: to)
            }
            slots.insert(slots.remove(at: from), at: to)
            return .move(from: to, to: from)
        }
    }

    private func perform(_ edit: Edit, name: String) {
        let inverse = apply(edit)
        // Each edit is a step of its own, also when nothing closes the step after it (as an event would).
        let ownStep = undoManager.groupingLevel == 0 && !undoManager.isUndoing && !undoManager.isRedoing
        if ownStep { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { editor in editor.perform(inverse, name: name) }
        undoManager.setActionName(name)
        if ownStep { undoManager.endUndoGrouping() }
        session.pagesChanged()
        onChange?()
    }

    /// Turns a page a quarter turn.
    func turn(_ index: Int, clockwise: Bool) {
        guard slots.indices.contains(index) else { return }
        perform(.turn(index, to: (slots[index].rotation + (clockwise ? 90 : 270)) % 360), name: L("Rotate Page"))
    }

    /// Takes a page out. The last page cannot be taken out.
    func takeOut(_ index: Int) {
        guard slots.indices.contains(index), slots.count > 1 else { return }
        perform(.takeOut(index..<(index + 1)), name: L("Delete Page"))
    }

    /// Moves a page to the gap before page `gap` (counted before the move; `slots.count` is the end).
    func move(_ index: Int, toGap gap: Int) {
        guard slots.indices.contains(index), (0...slots.count).contains(gap) else { return }
        let target = gap > index ? gap - 1 : gap
        guard target != index else { return }
        perform(.move(from: index, to: target), name: L("Move Page"))
    }

    /// Inserts every page of a source at the gap before page `gap`.
    func insert(_ source: Source, atGap gap: Int) {
        guard (0...slots.count).contains(gap), source.document.pageCount > 0 else { return }
        let number = sources.count
        sources.append(source)
        let pages = (0..<source.document.pageCount).compactMap { k -> (page: PDFPage, slot: PageSlot)? in
            guard let page = source.document.page(at: k) else { return nil }
            return (page, PageSlot(.inserted(source: number, page: k), rotation: page.rotation))
        }
        perform(.putIn(pages, at: gap), name: L("Insert Pages"))
    }

    /// Reads a file to insert pages from. Called away from the main thread.
    static func loadSource(_ url: URL) -> Result<Source, InsertProblem> {
        // Read whole, not mapped: the file may change on disk before the pages are saved.
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        if let reason = PDFPageWriter.reasonPagesCannotBeInserted(from: data) {
            if case .refused(let why) = reason { return .failure(.refused(why)) }
            return .failure(.damaged)
        }
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { return .failure(.unreadable) }
        return .success(Source(url: url, data: data, document: document))
    }

    enum InsertProblem: Error {
        case unreadable, damaged
        /// The writer's reason, as PDFAppendError.refused gives it.
        case refused(String)
    }
}
