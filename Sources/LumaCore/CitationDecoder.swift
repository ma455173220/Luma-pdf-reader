import CoreGraphics
import Foundation
import PDFKit

/// Links worked out from a document's text for citations it carries no links for: each number of a
/// citation leads to its entry in the reference list.
///
/// Nothing is read until asked: the reference list when the first page is asked for, each page the
/// first time it is asked for. What has been worked out is kept, and is small.
public final class CitationDecoder {
    /// What decoding needs to know about the whole document before it reads any page: its reference
    /// list (nil when it has no numbered one), the size of its running text and how it writes citations.
    public struct Preparation {
        public let list: ReferenceList?
        public let bodySize: CGFloat
        let forms: Set<CitationMarkers.Kind>
        let pageCount: Int
        /// The document links its own citations: none are worked out, only its references to figures
        /// and tables (from a document of the decoder's own, ADR 0006).
        public var linksItsOwnCitations = false
    }

    private let document: PDFDocument
    private var list: ReferenceList??
    private var forms: Set<CitationMarkers.Kind>?
    private var bodySize: CGFloat?
    private var pages: [Int: [PageLink]] = [:]

    public init(document: PDFDocument) {
        self.document = document
    }

    /// A decoder for a document whose preparation was done elsewhere (see `prepare(fileAt:)`).
    public init(document: PDFDocument, preparation: Preparation) {
        self.document = document
        list = .some(preparation.list)
        bodySize = preparation.bodySize
        forms = preparation.forms
    }

    /// Prepares decoding for the file at `url`, on any thread: the file is opened as a document of
    /// its own, so nothing is shared with a document shown on screen, and let go of afterwards. Nil
    /// for a file that is locked. For one that links its own citations, only the size of its running
    /// text, for finding its figures' captions.
    public static func prepare(fileAt url: URL) -> Preparation? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        let ownLinks = carriesCitationLinks(document)
        let decoder = CitationDecoder(document: document)
        guard !ownLinks, let list = decoder.referenceList else {
            // No numbered list, or citations linked already: only the size of the running text, from a
            // couple of pages past the title page.
            let first = document.pageCount > 2 ? 1 : 0
            let size = CitationMarkers.bodySize(of: (first..<min(first + 2, document.pageCount)).compactMap { document.page(at: $0) }) ?? 0
            var preparation = Preparation(list: nil, bodySize: size, forms: [], pageCount: document.pageCount)
            preparation.linksItsOwnCitations = ownLinks
            return preparation
        }
        _ = decoder.markers(onPage: 0)
        return Preparation(list: list, bodySize: decoder.bodySize ?? 0, forms: decoder.forms ?? Set(CitationMarkers.Kind.allCases),
                           pageCount: document.pageCount)
    }

    /// Whether a document links its own citations: links on its first pages that lead to later pages.
    /// Such a document is left to its own links for citations. Reading the text of the document shown
    /// costs memory the system does not give back, and it would only add the few citations its own
    /// links leave out.
    public static func carriesCitationLinks(_ document: PDFDocument) -> Bool {
        var count = 0
        for index in 0..<min(4, document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            count += PageLinks.links(on: page, in: document).filter { if case .place(let target, _) = $0.target { return target > index } else { return false } }.count
            if count >= 3 { return true }
        }
        return false
    }

    /// Whether a preparation was made from this very document (the file may have changed since).
    public static func fits(_ preparation: Preparation, _ document: PDFDocument) -> Bool {
        preparation.pageCount == document.pageCount
    }

    /// The document's numbered reference list, if it has one.
    public var referenceList: ReferenceList? {
        if case .some(let found) = list { return found }
        let found = ReferenceList.find(in: document)
        list = .some(found)
        return found
    }

    /// The citations found on a page.
    public func markers(onPage index: Int) -> [CitationMarker] {
        guard let list = referenceList, index <= list.startPage else { return [] }
        return markers(onPage: index, in: list, kinds: citationForms(in: list))
    }

    private func markers(onPage index: Int, in list: ReferenceList, kinds: Set<CitationMarkers.Kind>) -> [CitationMarker] {
        guard let page = document.page(at: index) else { return [] }
        if bodySize == nil {
            // The running text's size, from a few pages of the body (past the title page, when there are some).
            let first = list.startPage >= 3 ? 1 : 0
            bodySize = CitationMarkers.bodySize(of: (first...min(first + 1, list.startPage)).compactMap { document.page(at: $0) }) ?? 0
        }
        return CitationMarkers.find(on: page, index: index, endOffset: index == list.startPage ? list.startOffset : nil,
                                    entryCount: list.count, kinds: kinds, bodySize: bodySize)
            .filter { $0.numbers.allSatisfy { list.entries[$0] != nil } }
    }

    /// How this document writes its citations, from its first pages: in brackets, raised, or both.
    /// A paper that cites in brackets has no raised citations, so raised numbers there (affiliation
    /// marks, exponents) are not looked at, and the other way round.
    private func citationForms(in list: ReferenceList) -> Set<CitationMarkers.Kind> {
        if let forms { return forms }
        var brackets = 0, raised = 0
        for index in min(1, list.startPage)...min(2, list.startPage) {
            brackets += markers(onPage: index, in: list, kinds: [.brackets]).count
            raised += markers(onPage: index, in: list, kinds: [.raised]).count
        }
        var found: Set<CitationMarkers.Kind> = [.brackets, .raised, .written]
        if brackets >= 3 && raised * 3 <= brackets { found.remove(.raised) }
        if raised >= 3 && brackets * 3 <= raised { found.remove(.brackets) }
        forms = found
        return found
    }

    /// Links for the citations on a page, leaving out any that would lie over one of `existing`.
    public func links(onPage index: Int, besides existing: [PageLink] = []) -> [PageLink] {
        if let cached = pages[index] { return cached }
        var links: [PageLink] = []
        if let list = referenceList {
            // Compared at the size the links get, so that none lies over a link already there.
            for marker in markers(onPage: index) where !existing.contains(where: { $0.rect.intersects(marker.rect.insetBy(dx: -1, dy: -1)) }) {
                // Each number written in the citation leads to its own entry; one written only as part
                // of a range does not get a place of its own.
                for part in marker.parts {
                    guard let entry = list.entries[part.number] else { continue }
                    links.append(PageLink(rect: part.rect.insetBy(dx: -1, dy: -1), target: .place(page: entry.page, point: entry.point)))
                }
            }
        }
        pages[index] = links
        return links
    }
}
