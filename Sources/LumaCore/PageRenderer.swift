import CoreGraphics
import PDFKit

/// Paints pages with the system PDF engine. Keeps no images: whatever is asked for is painted and forgotten.
public enum PageRenderer {
    /// The size a page takes up on screen at scale 1, with its rotation applied.
    public static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// Paints `page` so that it exactly fills `frame`, in a context whose y axis grows downward.
    public static func draw(_ page: PDFPage, in frame: CGRect, context: CGContext) {
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(frame)
        context.clip(to: frame)
        // The engine paints with y growing upward from the page's bottom-left corner, and applies
        // the page's own rotation and crop offset itself.
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: frame.width / size.width, y: -frame.height / size.height)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }
}
