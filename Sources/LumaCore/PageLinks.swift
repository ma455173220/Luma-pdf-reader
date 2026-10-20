import CoreGraphics
import Foundation
import PDFKit

/// A clickable area of a page and where it leads.
public struct PageLink: Equatable {
    public enum Target: Equatable {
        /// Another place in the same document. `point` is in the target page's own coordinates;
        /// nil when the link only names the page.
        case place(page: Int, point: CGPoint?)
        case web(URL)
        /// A figure or table named in the text, whose place is looked for only when the link is used
        /// (see `FigureDecoder.resolved(_:onPage:)`).
        case figure(kind: FigureKind, number: Int, chinese: Bool)
    }

    /// In the page's own coordinates.
    public let rect: CGRect
    public let target: Target

    public init(rect: CGRect, target: Target) {
        self.rect = rect
        self.target = target
    }
}

public enum PageLinks {
    /// The links a document carries on one page. Only links that lead somewhere usable are returned:
    /// places inside the same document, and web or mail addresses.
    public static func links(on page: PDFPage, in document: PDFDocument) -> [PageLink] {
        page.annotations.compactMap { annotation in
            guard annotation.type == "Link" else { return nil }
            if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
               let targetPage = destination.page {
                let index = document.index(for: targetPage)
                guard index != NSNotFound, index >= 0, index < document.pageCount else { return nil }
                // A destination may name a spot, only a height, or nothing but the page.
                let raw = destination.point
                guard raw.y != kPDFDestinationUnspecifiedValue else {
                    return PageLink(rect: annotation.bounds, target: .place(page: index, point: nil))
                }
                let x = raw.x != kPDFDestinationUnspecifiedValue ? raw.x : targetPage.bounds(for: .cropBox).minX
                return PageLink(rect: annotation.bounds, target: .place(page: index, point: CGPoint(x: x, y: raw.y)))
            }
            if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url, isSafeToOpen(url) {
                return PageLink(rect: annotation.bounds, target: .web(url))
            }
            return nil
        }
    }

    /// Only addresses a browser or mail program handles. A link to a local file or a script is ignored.
    public static func isSafeToOpen(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The link under a point of the page. Where links overlap, the one listed last lies on top.
    public static func link(at pagePoint: CGPoint, in links: [PageLink]) -> PageLink? {
        links.last { $0.rect.contains(pagePoint) }
    }
}
