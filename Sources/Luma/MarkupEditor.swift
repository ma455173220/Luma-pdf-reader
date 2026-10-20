import AppKit
import LumaCore
import PDFKit

/// The four colours a mark can have, in the order the markup panel shows them.
enum MarkColour: Int, CaseIterable {
    case yellow, red, green, blue

    var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .yellow: return (1, 0.92, 0.23)
        case .red: return (1, 0.45, 0.45)
        case .green: return (0.45, 0.85, 0.45)
        case .blue: return (0.45, 0.7, 1)
        }
    }

    var color: NSColor {
        let c = components
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    /// The colour of this set that a mark has, if it is one of them. A mark made elsewhere in another
    /// colour has none, so that choosing any of the four changes it.
    static func exact(_ color: NSColor) -> MarkColour? {
        allCases.first { MarkupEditor.look(of: $0.color) == MarkupEditor.look(of: color) }
    }
}

/// The marks the reader makes in one document, kept as the system engine's annotation objects so
/// that they show on the page at once, together with what has to be written to the file on saving.
///
/// What is in the file is never touched here. Saving turns what this records into additions,
/// changes and removals for the append writer.
final class MarkupEditor {
    let undoManager: UndoManager = {
        let manager = UndoManager()
        // Each step keeps a copy of the bookkeeping; a limit keeps a long session without saving small.
        manager.levelsOfUndo = 50
        return manager
    }()
    /// Called after every change, including undo and redo.
    var onChange: (() -> Void)?

    private unowned let session: DocumentSession

    /// Marks made since the last save, with the page they are on. Pages are kept, not their numbers:
    /// page edits move pages about, and a mark on a page that was taken out is not saved.
    private var added: [ObjectIdentifier: (page: PDFPage, annotation: PDFAnnotation)] = [:]
    /// Marks that are in the file and have been touched since, with what identifies them there and
    /// how they looked in the file. Only a difference from that look is a change to save.
    private var originals: [ObjectIdentifier: (page: PDFPage, key: ExistingMarkup, annotation: PDFAnnotation, before: Look)] = [:]
    private var removed = Set<ObjectIdentifier>()

    init(session: DocumentSession) {
        self.session = session
    }

    var hasUnsavedChanges: Bool {
        added.values.contains { inDocument($0.page) }
            || originals.contains { inDocument($0.value.page) && (removed.contains($0.key) || MarkupEditor.look(of: $0.value.annotation) != $0.value.before) }
    }

    /// The page's place in the document now, or nil if a page edit took it out.
    private func index(of page: PDFPage) -> Int? {
        let index = session.document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    private func inDocument(_ page: PDFPage) -> Bool { index(of: page) != nil }

    static func isMark(_ annotation: PDFAnnotation) -> Bool {
        MarkupAddition.Kind(rawValue: annotation.type ?? "") != nil
    }

    // MARK: Snapshots for undo

    private struct Tracking {
        var added: [ObjectIdentifier: (page: PDFPage, annotation: PDFAnnotation)]
        var originals: [ObjectIdentifier: (page: PDFPage, key: ExistingMarkup, annotation: PDFAnnotation, before: Look)]
        var removed: Set<ObjectIdentifier>
    }

    private var tracking: Tracking {
        get { Tracking(added: added, originals: originals, removed: removed) }
        set {
            added = newValue.added
            originals = newValue.originals
            removed = newValue.removed
        }
    }

    /// Records an undoable step: `undo` must put the annotations back as they were; the bookkeeping is restored with it.
    private func registerUndo(_ name: String, before: Tracking, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        let after = tracking
        undoManager.registerUndo(withTarget: self) { editor in
            undo()
            editor.tracking = before
            editor.registerUndo(name, before: after, undo: redo, redo: undo)
            editor.onChange?()
        }
        undoManager.setActionName(name)
    }

    /// Notes what identifies an existing mark in the file, the first time it is changed.
    private func rememberOriginal(_ annotation: PDFAnnotation) {
        let id = ObjectIdentifier(annotation)
        guard added[id] == nil, originals[id] == nil, let page = annotation.page, inDocument(page) else { return }
        originals[id] = (page, ExistingMarkup(kind: MarkupEditor.kind(of: annotation), rect: annotation.bounds), annotation, MarkupEditor.look(of: annotation))
    }

    // MARK: Changes

    /// The lines of the selection on a page, and the box around them.
    private static func lines(of selection: PDFSelection, on page: PDFPage) -> (rects: [CGRect], bounds: CGRect)? {
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard let first = rects.first else { return nil }
        return (rects, rects.dropFirst().reduce(first) { $0.union($1) })
    }

    /// The mark of this kind already on exactly these lines of the page, if any. Measured by the
    /// lines it covers: a saved underline's own rectangle reaches beyond them.
    private static func twin(of kind: MarkupAddition.Kind, over bounds: CGRect, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { isMark($0) && self.kind(of: $0) == kind && sameRect(linesBox(of: $0), bounds) }
    }

    /// Whether marking the selection this way would meet two marks of that kind already on the same
    /// text, which the file cannot tell apart. Such text is not marked again; the reader is told.
    func meetsMarksThatCannotBeToldApart(_ selection: PDFSelection, kind: MarkupAddition.Kind) -> Bool {
        selection.pages.contains { page in
            guard let lines = MarkupEditor.lines(of: selection, on: page),
                  let twin = MarkupEditor.twin(of: kind, over: lines.bounds, on: page) else { return false }
            return cannotBeToldApart(twin)
        }
    }

    /// Marks the selected text, one annotation per page it runs over.
    @discardableResult
    func mark(_ selection: PDFSelection, kind: MarkupAddition.Kind, colour: MarkColour, note: String? = nil) -> [PDFAnnotation] {
        let before = tracking
        let note = MarkupEditor.normalNote(note)
        var made: [(PDFPage, PDFAnnotation)] = []
        // Marking text that already carries the very same mark changes that mark instead of laying a
        // second one exactly on top of it, which could then never be told apart in the file.
        var restyled: [(annotation: PDFAnnotation, colour: NSColor, note: String?)] = []
        for page in selection.pages {
            let index = session.document.index(for: page)
            guard let (rects, bounds) = MarkupEditor.lines(of: selection, on: page), index != NSNotFound else { continue }
            if let twin = MarkupEditor.twin(of: kind, over: bounds, on: page) {
                // Two such marks already, which the file cannot tell apart: they are left as they are
                // (the app asks meetsMarksThatCannotBeToldApart first and tells the reader).
                if cannotBeToldApart(twin) { continue }
                restyled.append((twin, twin.color, twin.contents))
                rememberOriginal(twin)
                twin.color = colour.color
                if let note { twin.contents = note }
                continue
            }
            let annotation = PDFAnnotation(bounds: bounds, forType: PDFAnnotationSubtype(rawValue: kind.rawValue), withProperties: nil)
            // The engine wants each line's corners, named as the text reads, measured from the
            // annotation's own corner.
            annotation.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                let quad = PageGeometry.textQuad(forPageRect: r, on: page)
                return [quad.topLeft, quad.topRight, quad.bottomLeft, quad.bottomRight].map { NSValue(point: NSPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
            }
            annotation.color = colour.color
            if let note { annotation.contents = note }
            page.addAnnotation(annotation)
            added[ObjectIdentifier(annotation)] = (page, annotation)
            made.append((page, annotation))
        }
        guard !made.isEmpty || !restyled.isEmpty else { return [] }
        let newColour = colour.color
        registerUndo(MarkupEditor.name(of: kind), before: before,
                     undo: {
                         for (page, annotation) in made { page.removeAnnotation(annotation) }
                         for item in restyled { item.annotation.color = item.colour; item.annotation.contents = item.note }
                     },
                     redo: {
                         for (page, annotation) in made { page.addAnnotation(annotation) }
                         for item in restyled { item.annotation.color = newColour; if let note { item.annotation.contents = note } }
                     })
        onChange?()
        return made.map(\.1) + restyled.map(\.annotation)
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.maxX - b.maxX) <= 0.5 && abs(a.maxY - b.maxY) <= 0.5
    }

    /// The upright box around the lines a mark covers.
    private static func linesBox(of annotation: PDFAnnotation) -> CGRect {
        let boxes = pageQuads(of: annotation).map { q -> CGRect in
            let xs = [q.topLeft.x, q.topRight.x, q.bottomLeft.x, q.bottomRight.x], ys = [q.topLeft.y, q.topRight.y, q.bottomLeft.y, q.bottomRight.y]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        return boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
    }

    /// Whether a mark that is in the file has another of the same kind in the same place there:
    /// saving finds a mark by kind and place, so it could not tell which of the two was changed.
    /// Whether a mark from the file belongs with another annotation: it replies to one (/IRT), is
    /// grouped with one (/RT /Group, as a strikethrough made by "replace text" is with its caret), or
    /// another replies to it. Changing or deleting it alone would leave the other without its meaning,
    /// so 知白 leaves it as it is.
    func isTiedToAnother(_ annotation: PDFAnnotation) -> Bool {
        guard added[ObjectIdentifier(annotation)] == nil, let page = annotation.page else { return false }
        let inReplyTo = PDFAnnotationKey(rawValue: "/IRT"), replyType = PDFAnnotationKey(rawValue: "/RT")
        if annotation.value(forAnnotationKey: inReplyTo) != nil || annotation.value(forAnnotationKey: replyType) != nil { return true }
        return page.annotations.contains { other in
            other !== annotation && (other.value(forAnnotationKey: inReplyTo) as? PDFAnnotation) === annotation
        }
    }

    func cannotBeToldApart(_ annotation: PDFAnnotation) -> Bool {
        guard added[ObjectIdentifier(annotation)] == nil, let page = annotation.page else { return false }
        return page.annotations.contains { other in
            other !== annotation && added[ObjectIdentifier(other)] == nil && MarkupEditor.isMark(other)
                && MarkupEditor.kind(of: other) == MarkupEditor.kind(of: annotation) && MarkupEditor.sameRect(other.bounds, annotation.bounds)
        }
    }

    func setColour(_ colour: MarkColour, of annotation: PDFAnnotation) {
        guard MarkupEditor.look(of: annotation).colour != MarkupEditor.look(of: colour.color) else { return }
        let before = tracking
        let previous = annotation.color
        rememberOriginal(annotation)
        annotation.color = colour.color
        registerUndo(L("Change Color"), before: before, undo: { annotation.color = previous }, redo: { annotation.color = colour.color })
        onChange?()
    }

    func setNote(_ note: String, of annotation: PDFAnnotation) {
        let text = MarkupEditor.normalNote(note)
        let previous = annotation.contents
        // Notes are compared without the spaces and line ends around them, here and when saving: a
        // note that differs only by those is not changed, and is left in the file exactly as it is.
        guard text != MarkupEditor.normalNote(previous) else { return }
        let before = tracking
        rememberOriginal(annotation)
        annotation.contents = text
        registerUndo(L("Change Note"), before: before, undo: { annotation.contents = previous }, redo: { annotation.contents = text })
        onChange?()
    }

    func delete(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        let before = tracking
        let id = ObjectIdentifier(annotation)
        if added[id] != nil {
            added[id] = nil
        } else {
            rememberOriginal(annotation)
            removed.insert(id)
        }
        page.removeAnnotation(annotation)
        registerUndo(L("Delete Annotation"), before: before, undo: { page.addAnnotation(annotation) }, redo: { page.removeAnnotation(annotation) })
        onChange?()
    }

    // MARK: Saving

    private static func components(of color: NSColor) -> (Double, Double, Double) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    private static func kind(of annotation: PDFAnnotation) -> MarkupAddition.Kind {
        MarkupAddition.Kind(rawValue: annotation.type ?? "") ?? .highlight
    }

    /// A kind of mark as the interface names it.
    static func name(of kind: MarkupAddition.Kind) -> String {
        switch kind {
        case .highlight: return L("Highlight")
        case .underline: return L("Underline")
        case .strikeOut: return L("Strikethrough")
        }
    }

    /// The corners of each marked line, in page coordinates.
    private static func pageQuads(of annotation: PDFAnnotation) -> [MarkupQuad] {
        let origin = annotation.bounds.origin
        let points = annotation.quadrilateralPoints?.map { $0.pointValue } ?? []
        func onPage(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }
        let quads = stride(from: 0, to: points.count - 3, by: 4).map { i in
            MarkupQuad(topLeft: onPage(points[i]), topRight: onPage(points[i + 1]), bottomLeft: onPage(points[i + 2]), bottomRight: onPage(points[i + 3]))
        }
        return quads.isEmpty ? [MarkupQuad(annotation.bounds)] : quads
    }

    /// What saving has to write: new marks, and changes to or removals of marks already in the file.
    func changesForSaving() -> [MarkupChange] {
        changes(adding: additionsInOrder()).map(\.change)
    }

    /// The new marks in the order saving hands them to the writer, with the number their page has
    /// now. Marks on pages taken out are left out.
    private func additionsInOrder() -> [(id: ObjectIdentifier, page: Int, annotation: PDFAnnotation)] {
        added.compactMap { entry in index(of: entry.value.page).map { (id: entry.key, page: $0, annotation: entry.value.annotation) } }
            .sorted { $0.page < $1.page }
    }

    /// The changes, each with the mark it comes from.
    private func changes(adding additions: [(id: ObjectIdentifier, page: Int, annotation: PDFAnnotation)]) -> [(change: MarkupChange, source: ObjectIdentifier)] {
        var changes: [(change: MarkupChange, source: ObjectIdentifier)] = []
        for entry in additions {
            let annotation = entry.annotation
            let (r, g, b) = MarkupEditor.components(of: annotation.color)
            changes.append((.add(MarkupAddition(pageIndex: entry.page, kind: MarkupEditor.kind(of: annotation), quads: MarkupEditor.pageQuads(of: annotation),
                                                red: r, green: g, blue: b, note: annotation.contents)), entry.id))
        }
        for (id, entry) in originals {
            // A change to a mark on a page taken out goes with the page.
            guard let page = index(of: entry.page) else { continue }
            if removed.contains(id) {
                changes.append((.remove(page: page, original: entry.key), id))
                continue
            }
            // Only what differs from the file is written; the rest is left there byte for byte.
            let now = MarkupEditor.look(of: entry.annotation)
            let colour = now.colour == entry.before.colour ? nil : MarkupColour(red: now.colour[0], green: now.colour[1], blue: now.colour[2])
            let note: NoteChange = now.note == entry.before.note ? .unchanged : .set(now.note)
            if colour != nil || note != .unchanged {
                changes.append((.modify(page: page, original: entry.key, colour: colour, note: note), id))
            }
        }
        return changes
    }

    /// Puts unsaved changes made while reading an earlier version of the file onto this one, after
    /// the file was reloaded. A new mark goes back only where the same text is still under it; a
    /// change to a mark, or its removal, only where that mark is still in the same place. Returns
    /// the changes that could not be put back. With `onlyCheck`, nothing is changed.
    ///
    /// Putting the changes back is one step that can be undone, so that a change the file will not
    /// take can still be dropped.
    @discardableResult
    func reapply(_ changes: [MarkupChange], from earlier: PDFDocument, onlyCheck: Bool = false) -> [MarkupChange] {
        reapply(changes, from: { earlier.page(at: $0) }, onlyCheck: onlyCheck)
    }

    /// The same, with the earlier reading's page for each page number of the changes given by
    /// `earlier`: after page edits, the page a change was made on is not at the same place.
    func reapply(_ changes: [MarkupChange], from earlier: (Int) -> PDFPage?, onlyCheck: Bool = false) -> [MarkupChange] {
        let before = tracking
        var unplaced: [MarkupChange] = []
        var placed: [(page: PDFPage, annotation: PDFAnnotation)] = []
        var restyled: [(annotation: PDFAnnotation, colour: NSColor, note: String?)] = []
        var taken: [(page: PDFPage, annotation: PDFAnnotation)] = []
        // Changes to marks in the file go first, while the pages hold only those: a new mark put back
        // first could be taken for the one a change was made to. The check runs in the same order.
        let additions = changes.filter { if case .add = $0 { return true } else { return false } }
        for change in changes.filter({ if case .add = $0 { return false } else { return true } }) + additions {
            switch change {
            case .add(let addition):
                guard let page = session.document.page(at: addition.pageIndex), let earlierPage = earlier(addition.pageIndex),
                      MarkupEditor.text(under: addition.quads, on: page) == MarkupEditor.text(under: addition.quads, on: earlierPage) else {
                    unplaced.append(change)
                    continue
                }
                if !onlyCheck, let annotation = place(addition, on: page) { placed.append((page, annotation)) }
            case .modify(let pageIndex, let original, let colour, let note):
                guard let annotation = existing(original, onPage: pageIndex), sameText(under: original, onPage: pageIndex, as: earlier(pageIndex)) else {
                    unplaced.append(change)
                    continue
                }
                if !onlyCheck {
                    // Only what the reader changed goes back: a note another program changed meanwhile stays.
                    restyled.append((annotation, annotation.color, annotation.contents))
                    rememberOriginal(annotation)
                    if let colour { annotation.color = NSColor(srgbRed: colour.red, green: colour.green, blue: colour.blue, alpha: 1) }
                    if case .set(let text) = note { annotation.contents = (text ?? "").isEmpty ? nil : text }
                }
            case .remove(let pageIndex, let original):
                guard let annotation = existing(original, onPage: pageIndex), let page = annotation.page,
                      sameText(under: original, onPage: pageIndex, as: earlier(pageIndex)) else {
                    unplaced.append(change)
                    continue
                }
                if !onlyCheck {
                    rememberOriginal(annotation)
                    removed.insert(ObjectIdentifier(annotation))
                    page.removeAnnotation(annotation)
                    taken.append((page, annotation))
                }
            }
        }
        if !onlyCheck && !(placed.isEmpty && restyled.isEmpty && taken.isEmpty) {
            let after = restyled.map { (annotation: $0.annotation, colour: $0.annotation.color, note: $0.annotation.contents) }
            registerUndo(L("Restore Annotation"), before: before,
                         undo: {
                             for (page, annotation) in placed { page.removeAnnotation(annotation) }
                             for item in restyled { item.annotation.color = item.colour; item.annotation.contents = item.note }
                             for (page, annotation) in taken { page.addAnnotation(annotation) }
                         },
                         redo: {
                             for (page, annotation) in placed { page.addAnnotation(annotation) }
                             for item in after { item.annotation.color = item.colour; item.annotation.contents = item.note }
                             for (page, annotation) in taken { page.removeAnnotation(annotation) }
                         })
            onChange?()
        }
        return unplaced
    }

    /// The one mark on a page that a change was made to, found the way saving finds it: same kind,
    /// same place, among the marks in the file (not new ones put back).
    private func existing(_ key: ExistingMarkup, onPage index: Int) -> PDFAnnotation? {
        guard let page = session.document.page(at: index) else { return nil }
        let matches = page.annotations.filter { annotation in
            let r = annotation.bounds
            return added[ObjectIdentifier(annotation)] == nil && MarkupEditor.isMark(annotation) && MarkupEditor.kind(of: annotation) == key.kind
                && abs(r.minX - key.rect.minX) <= 0.5 && abs(r.minY - key.rect.minY) <= 0.5
                && abs(r.maxX - key.rect.maxX) <= 0.5 && abs(r.maxY - key.rect.maxY) <= 0.5
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Whether the place a mark was in still has the same words under it as in the earlier reading:
    /// a page put in front would otherwise bring a different mark to the same place.
    private func sameText(under key: ExistingMarkup, onPage index: Int, as earlierPage: PDFPage?) -> Bool {
        guard let page = session.document.page(at: index), let earlierPage else { return false }
        let area = [MarkupQuad(key.rect)]
        return MarkupEditor.text(under: area, on: page) == MarkupEditor.text(under: area, on: earlierPage)
    }

    /// The text under a mark's lines, without spaces, for telling whether it still covers the same words.
    private static func text(under quads: [MarkupQuad], on page: PDFPage) -> String {
        quads.compactMap { quad -> String? in
            let xs = [quad.topLeft.x, quad.topRight.x, quad.bottomLeft.x, quad.bottomRight.x]
            let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomLeft.y, quad.bottomRight.y]
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return page.selection(for: rect)?.string
        }.joined().filter { !$0.isWhitespace }
    }

    private func place(_ addition: MarkupAddition, on page: PDFPage) -> PDFAnnotation? {
        let points = addition.quads.flatMap { [$0.topLeft, $0.topRight, $0.bottomLeft, $0.bottomRight] }
        guard let first = points.first else { return nil }
        let bounds = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let annotation = PDFAnnotation(bounds: bounds, forType: PDFAnnotationSubtype(rawValue: addition.kind.rawValue), withProperties: nil)
        annotation.quadrilateralPoints = points.map { NSValue(point: NSPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
        annotation.color = NSColor(srgbRed: addition.red, green: addition.green, blue: addition.blue, alpha: 1)
        if let note = addition.note, !note.isEmpty { annotation.contents = note }
        page.addAnnotation(annotation)
        added[ObjectIdentifier(annotation)] = (page, annotation)
        return annotation
    }

    /// How a mark looks, to tell afterwards whether it was changed while its save was being written.
    fileprivate struct Look: Equatable {
        var colour: [Double]
        var note: String?
        var onPage: Bool
    }

    fileprivate static func look(of annotation: PDFAnnotation) -> Look {
        Look(colour: look(of: annotation.color), note: normalNote(annotation.contents), onPage: annotation.page != nil)
    }

    /// A note as marks keep and compare it: without spaces or line ends around it, none when empty.
    private static func normalNote(_ note: String?) -> String? {
        let text = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// A colour as three parts, rounded so that the same colour read twice compares equal.
    fileprivate static func look(of color: NSColor) -> [Double] {
        let (r, g, b) = components(of: color)
        return [r, g, b].map { ($0 * 1000).rounded() / 1000 }
    }

    /// What a save is writing: the changes, and the state of every mark they come from.
    struct Saving {
        let changes: [MarkupChange]
        /// The mark each change comes from, in the order of `changes`.
        fileprivate let sources: [ObjectIdentifier]
        /// The new marks, in the order of the additions among `changes`.
        fileprivate let addedOrder: [ObjectIdentifier]
        fileprivate let added: [ObjectIdentifier: (page: PDFPage, annotation: PDFAnnotation, look: Look)]
        fileprivate let originals: [ObjectIdentifier: Look]
        fileprivate let removed: Set<ObjectIdentifier>
    }

    func startSaving() -> Saving {
        let additions = additionsInOrder()
        let changes = changes(adding: additions)
        return Saving(changes: changes.map(\.change), sources: changes.map(\.source), addedOrder: additions.map(\.id),
               added: added.mapValues { ($0.page, $0.annotation, MarkupEditor.look(of: $0.annotation)) },
               originals: originals.mapValues { MarkupEditor.look(of: $0.annotation) },
               removed: removed)
    }

    /// Drops the reader's change to the mark one change of a save comes from, putting the mark back
    /// the way the file has it: for a change the file will not take, so that the rest can be saved.
    /// Undo is cleared, since earlier steps may refer to the dropped change.
    func discard(changeAt position: Int, of saving: Saving) {
        guard saving.sources.indices.contains(position) else { return }
        let id = saving.sources[position]
        if let entry = added[id] {
            entry.annotation.page?.removeAnnotation(entry.annotation)
            added[id] = nil
        } else if let entry = originals[id] {
            let annotation = entry.annotation
            if annotation.page == nil, inDocument(entry.page) { entry.page.addAnnotation(annotation) }
            let colour = entry.before.colour
            if MarkupEditor.look(of: annotation.color) != colour {
                annotation.color = NSColor(srgbRed: colour[0], green: colour[1], blue: colour[2], alpha: 1)
            }
            if MarkupEditor.normalNote(annotation.contents) != entry.before.note { annotation.contents = entry.before.note }
            originals[id] = nil
            removed.remove(id)
        }
        undoManager.removeAllActions()
        onChange?()
    }

    /// After a successful save, exactly what was written counts as saved. A mark changed, made or
    /// deleted while the file was being written stays an unsaved change, now measured against the
    /// file. Undo is cleared: an undo now would have to change the file again, which it cannot express.
    /// `newRects` are the rectangles the writer gave the new marks, in the order they were handed to it.
    func didSave(_ saving: Saving, newRects: [CGRect]) {
        let rects = saving.addedOrder.count == newRects.count ? Dictionary(uniqueKeysWithValues: zip(saving.addedOrder, newRects)) : [:]
        for (id, entry) in saving.added {
            let annotation = entry.annotation
            // In the file, a new mark's rectangle is its drawing's, which for an underline reaches beyond
            // the text. The mark takes the very rectangle written, so that a later change finds it there.
            let quads = MarkupEditor.pageQuads(of: annotation)
            if let written = rects[id], written.width > 0, written.height > 0 {
                annotation.bounds = written
                annotation.quadrilateralPoints = quads.flatMap { q in
                    [q.topLeft, q.topRight, q.bottomLeft, q.bottomRight].map { NSValue(point: NSPoint(x: $0.x - written.minX, y: $0.y - written.minY)) }
                }
            }
            added[id] = nil
            let now = MarkupEditor.look(of: annotation)
            if now != entry.look {
                // Changed or deleted after the file took it: a change to a mark that is now in the file.
                originals[id] = (entry.page, ExistingMarkup(kind: MarkupEditor.kind(of: annotation), rect: annotation.bounds), annotation, entry.look)
                if !now.onPage { removed.insert(id) }
            }
        }
        for (id, look) in saving.originals {
            guard let entry = originals[id] else { continue }
            if saving.removed.contains(id) {
                originals[id] = nil
                removed.remove(id)
            } else if MarkupEditor.look(of: entry.annotation) == look {
                originals[id] = nil
            } else {
                // Changed again while the file was being written: measured from what the file now holds.
                originals[id]?.before = look
            }
        }
        undoManager.removeAllActions()
        onChange?()
    }
}
