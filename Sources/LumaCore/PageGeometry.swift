import CoreGraphics
import PDFKit

/// Conversions between a page's own coordinates and where things appear on screen.
///
/// A PDF page measures from its bottom-left corner with y growing upward, may be rotated, and may
/// show only a cropped part of itself. On screen the page is measured from its top-left corner with
/// y growing downward, already rotated and cropped. "Display" coordinates below are that on-screen
/// measure at scale 1.
public enum PageGeometry {
    public static func displayPoint(forPagePoint point: CGPoint, on page: PDFPage) -> CGPoint {
        let upright = point.applying(page.transform(for: .cropBox))
        return CGPoint(x: upright.x, y: PageRenderer.displaySize(of: page).height - upright.y)
    }

    public static func pagePoint(forDisplayPoint point: CGPoint, on page: PDFPage) -> CGPoint {
        let height = PageRenderer.displaySize(of: page).height
        return CGPoint(x: point.x, y: height - point.y).applying(page.transform(for: .cropBox).inverted())
    }

    public static func displayRect(forPageRect rect: CGRect, on page: PDFPage) -> CGRect {
        let a = displayPoint(forPagePoint: CGPoint(x: rect.minX, y: rect.minY), on: page)
        let b = displayPoint(forPagePoint: CGPoint(x: rect.maxX, y: rect.maxY), on: page)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Which way a line of text reads on screen. A line lying across the screen reads to the right,
    /// even upside down: only text running up or down the page is told apart.
    public enum Reading { case right, down, up }

    /// Which way the line of text that occupies `rect` of the page reads on screen.
    ///
    /// A line across the screen is not looked into: the order the page numbers its characters in
    /// goes wrong too often for that (superscripts, citations and formulas are numbered apart from
    /// the words around them). A line running up or down is read at eight places along it; it runs
    /// one way when nearly every step does, so that a stray character does not turn it round. One
    /// too short to tell is taken as reading to the right.
    public static func reading(ofLineAt rect: CGRect, on page: PDFPage) -> Reading {
        let shown = displayRect(forPageRect: rect, on: page)
        guard shown.height > shown.width * 1.5 else { return .right }
        var order: [Int] = []
        for step in 0..<8 {
            let spot = CGPoint(x: shown.midX, y: shown.minY + shown.height * (CGFloat(step) + 0.5) / 8)
            let index = page.characterIndex(at: pagePoint(forDisplayPoint: spot, on: page))
            if index >= 0, index != NSNotFound, index != order.last { order.append(index) }
        }
        guard order.count >= 4 else { return .right }
        let steps = order.count - 1
        let downward = zip(order, order.dropFirst()).filter { $0 < $1 }.count
        if downward * 4 >= steps * 3 { return .down }
        if (steps - downward) * 4 >= steps * 3 { return .up }
        return .right
    }

    /// The quad of a line of text that occupies `rect` of the page, its corners named as the text
    /// reads on screen (top-left first), so that the bottom is under the words on a turned page and
    /// beside them where the text itself runs up or down the page.
    public static func textQuad(forPageRect rect: CGRect, on page: PDFPage) -> MarkupQuad {
        let s = displayRect(forPageRect: rect, on: page)
        func back(_ x: CGFloat, _ y: CGFloat) -> CGPoint { pagePoint(forDisplayPoint: CGPoint(x: x, y: y), on: page) }
        // On screen y grows downward; the corners in order top-left, top-right, bottom-left, bottom-right.
        let corners: [(CGFloat, CGFloat)]
        switch reading(ofLineAt: rect, on: page) {
        case .right: corners = [(s.minX, s.minY), (s.maxX, s.minY), (s.minX, s.maxY), (s.maxX, s.maxY)]
        case .down: corners = [(s.maxX, s.minY), (s.maxX, s.maxY), (s.minX, s.minY), (s.minX, s.maxY)]
        case .up: corners = [(s.minX, s.maxY), (s.minX, s.minY), (s.maxX, s.maxY), (s.maxX, s.minY)]
        }
        let p = corners.map { back($0.0, $0.1) }
        return MarkupQuad(topLeft: p[0], topRight: p[1], bottomLeft: p[2], bottomRight: p[3])
    }

    /// The page point under a point of the canvas, given where the page's frame sits on the canvas.
    public static func pagePoint(forCanvasPoint point: CGPoint, pageFrame frame: CGRect, page: PDFPage) -> CGPoint {
        let size = PageRenderer.displaySize(of: page)
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let display = CGPoint(x: (point.x - frame.minX) * size.width / frame.width, y: (point.y - frame.minY) * size.height / frame.height)
        return pagePoint(forDisplayPoint: display, on: page)
    }

    /// Where a rectangle of the page falls on the canvas.
    public static func canvasRect(forPageRect rect: CGRect, pageFrame frame: CGRect, page: PDFPage) -> CGRect {
        let size = PageRenderer.displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return .zero }
        let display = displayRect(forPageRect: rect, on: page)
        let sx = frame.width / size.width, sy = frame.height / size.height
        return CGRect(x: frame.minX + display.minX * sx, y: frame.minY + display.minY * sy, width: display.width * sx, height: display.height * sy)
    }
}
