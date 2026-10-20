import AppKit
import PDFKit
import XCTest
@testable import LumaCore

/// Checks that pages painted by the app land where the system engine's own thumbnail puts them,
/// for every rotation and for a crop box that does not start at the page corner.
final class PageRendererTests: XCTestCase {
    private func bitmap(width: Int, height: Int, _ paint: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            paint(context)
        }
        return pixels
    }

    /// The box around everything that is not white, in pixels from the top-left.
    private func inkBounds(_ pixels: [UInt8], width: Int, height: Int) -> CGRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] < 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? .null : CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func assertMatchesSystemThumbnail(_ file: MiniPDF, file source: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XCTUnwrap(PDFDocument(data: Data(file.classic())))
        let page = try XCTUnwrap(document.page(at: 0))
        let size = PageRenderer.displaySize(of: page)
        let width = Int(size.width), height = Int(size.height)

        let ours = bitmap(width: width, height: height) { context in
            // Give the context the canvas's orientation: origin at the top-left, y growing downward.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            PageRenderer.draw(page, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        }
        let reference = bitmap(width: width, height: height) { context in
            let thumbnail = page.thumbnail(of: NSSize(width: width, height: height), for: .cropBox)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            thumbnail.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }

        let a = inkBounds(ours, width: width, height: height), b = inkBounds(reference, width: width, height: height)
        XCTAssertFalse(b.isNull, "reference shows no text; the test file is wrong", file: source, line: line)
        XCTAssertFalse(a.isNull, "nothing was painted", file: source, line: line)
        for (ourEdge, referenceEdge) in [(a.minX, b.minX), (a.minY, b.minY), (a.maxX, b.maxX), (a.maxY, b.maxY)] {
            XCTAssertEqual(ourEdge, referenceEdge, accuracy: 3, "text is not where the system engine puts it", file: source, line: line)
        }
    }

    func testUprightPage() throws {
        try assertMatchesSystemThumbnail(MiniPDF())
    }

    func testRotatedPages() throws {
        for rotation in [90, 180, 270] {
            var file = MiniPDF()
            file.rotation = rotation
            try assertMatchesSystemThumbnail(file)
        }
    }

    func testCropBoxAwayFromThePageCorner() throws {
        var file = MiniPDF()
        file.cropBox = "[50 400 450 780]"
        try assertMatchesSystemThumbnail(file)
    }

    func testCropBoxOnARotatedPage() throws {
        var file = MiniPDF()
        file.cropBox = "[50 400 450 780]"
        file.rotation = 90
        try assertMatchesSystemThumbnail(file)
    }

    /// In use, a page is painted at some offset and some scale, not at the origin at full size.
    /// Nothing may be painted outside the frame it was given.
    func testPaintsAtAnyPlaceAndScaleAndStaysInsideItsFrame() throws {
        for rotation in [0, 90] {
            var file = MiniPDF()
            file.rotation = rotation
            let document = try XCTUnwrap(PDFDocument(data: Data(file.classic())))
            let page = try XCTUnwrap(document.page(at: 0))
            let size = PageRenderer.displaySize(of: page)
            let scale: CGFloat = 0.6
            let frame = CGRect(x: 37, y: 53, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            let width = Int(frame.maxX) + 40, height = Int(frame.maxY) + 40
            let marker: UInt8 = 200

            var canvas = [UInt8](repeating: marker, count: width * height * 4)
            canvas.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                PageRenderer.draw(page, in: frame, context: context)
            }

            // Outside the frame every pixel must still be the marker colour.
            var strayPixels = 0
            for y in 0..<height {
                for x in 0..<width where !frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) {
                    if canvas[(y * width + x) * 4] != marker { strayPixels += 1 }
                }
            }
            XCTAssertEqual(strayPixels, 0, "painted outside its frame (rotation \(rotation))")

            // Inside it, the text must sit where the system engine's thumbnail of the same size puts it.
            let w = Int(frame.width), h = Int(frame.height)
            var ours = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let source = ((y + Int(frame.minY)) * width + x + Int(frame.minX)) * 4
                    for k in 0..<4 { ours[(y * w + x) * 4 + k] = canvas[source + k] }
                }
            }
            let reference = bitmap(width: w, height: h) { context in
                let thumbnail = page.thumbnail(of: NSSize(width: w, height: h), for: .cropBox)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                thumbnail.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
            }
            let a = inkBounds(ours, width: w, height: h), b = inkBounds(reference, width: w, height: h)
            XCTAssertFalse(a.isNull, "nothing was painted (rotation \(rotation))")
            for (ourEdge, referenceEdge) in [(a.minX, b.minX), (a.minY, b.minY), (a.maxX, b.maxX), (a.maxY, b.maxY)] {
                XCTAssertEqual(ourEdge, referenceEdge, accuracy: 3, "text is not where the system engine puts it (rotation \(rotation))")
            }
        }
    }

    func testDisplaySizeSwapsForSidewaysPages() throws {
        var file = MiniPDF()
        file.rotation = 90
        let page = try XCTUnwrap(PDFDocument(data: Data(file.classic()))?.page(at: 0))
        XCTAssertEqual(PageRenderer.displaySize(of: page), CGSize(width: 792, height: 612))
    }
}
