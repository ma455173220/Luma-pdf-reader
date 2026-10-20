import Foundation
import PDFKit

/// A document of its own, opened from a file only to read text from, and let go of once it has not
/// been used for a while. The text the system engine reads from a page stays with the document it was
/// read from and is not given back while that document lives; read from this one instead of the
/// document shown, it goes when this one does (ADR 0006).
///
/// Used on the main thread only.
public final class TextReader {
    private let file: URL
    private let pageCount: Int
    /// Whether the file is still the one the document shown was read from (its size and date); a
    /// file replaced by another with as many pages is not read.
    private let isUnchanged: () -> Bool
    private var held: PDFDocument?
    private var release: DispatchWorkItem?
    /// How long the document is kept after its last use (初值).
    public var keptFor: TimeInterval
    /// How many previews may read from the document before it is let go of and opened afresh, so
    /// that the text read does not pile up while the reader goes on hovering without a pause (初值).
    public var usesBeforeRenewal = 30
    private var uses = 0

    /// `pageCount`: that of the document shown, which the file must still match, as `isUnchanged` must
    /// say it is.
    public init(file: URL, pageCount: Int, keptFor: TimeInterval = 10, isUnchanged: @escaping () -> Bool = { true }) {
        self.file = file
        self.pageCount = pageCount
        self.keptFor = keptFor
        self.isUnchanged = isUnchanged
    }

    /// The document, opened if need be, kept for a while from now. Nil when the file cannot be read,
    /// is locked, or no longer has the pages of the document shown.
    /// Counts one more preview shown from this document; after `usesBeforeRenewal` of them it is let
    /// go of, to be opened afresh when next needed. Called once per preview, so that nothing reading
    /// from it meanwhile (a selection, the figure decoder's pages) finds it opened afresh halfway.
    public func previewShown() {
        uses += 1
        if uses > usesBeforeRenewal { letGo() }
    }

    public var document: PDFDocument? {
        if held == nil {
            guard isUnchanged(), let opened = PDFDocument(url: file), !opened.isLocked, opened.pageCount == pageCount else { return nil }
            held = opened
        }
        release?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.letGo() }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keptFor, execute: work)
        return held
    }

    public func page(at index: Int) -> PDFPage? { document?.page(at: index) }

    /// Lets go of the document now, and of all text read from it.
    public func letGo() {
        release?.cancel()
        release = nil
        held = nil
        uses = 0
    }

    public var isHolding: Bool { held != nil }
}
