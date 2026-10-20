import PDFKit
import XCTest
@testable import LumaCore

/// The test page says "Hello page one" in 18-point type starting at (72, 700) in page coordinates.
final class PageGeometryTests: XCTestCase {
    private func page(rotation: Int = 0, cropBox: String? = nil) throws -> PDFPage {
        var file = MiniPDF()
        // No note on the page: its icon would count as ink and pull the measured text box off the text.
        file.annotations = .none
        file.rotation = rotation
        file.cropBox = cropBox
        return try XCTUnwrap(PDFDocument(data: Data(file.classic()))?.page(at: 0))
    }

    private func cases() throws -> [(String, PDFPage)] {
        var all: [(String, PDFPage)] = []
        for rotation in [0, 90, 180, 270] {
            all.append(("rotation \(rotation)", try page(rotation: rotation)))
            all.append(("rotation \(rotation), cropped", try page(rotation: rotation, cropBox: "[50 400 450 780]")))
        }
        return all
    }

    func testPageAndDisplayCoordinatesRoundTrip() throws {
        for (name, page) in try cases() {
            for point in [CGPoint(x: 72, y: 700), CGPoint(x: 300.5, y: 512.25), CGPoint(x: 449, y: 401)] {
                let back = PageGeometry.pagePoint(forDisplayPoint: PageGeometry.displayPoint(forPagePoint: point, on: page), on: page)
                XCTAssertEqual(back.x, point.x, accuracy: 0.001, name)
                XCTAssertEqual(back.y, point.y, accuracy: 0.001, name)
            }
        }
    }

    func testUprightPageMeasuresFromItsTopLeftCorner() throws {
        let upright = try page()
        XCTAssertEqual(PageGeometry.displayPoint(forPagePoint: CGPoint(x: 0, y: 792), on: upright), .zero)
        XCTAssertEqual(PageGeometry.displayPoint(forPagePoint: CGPoint(x: 72, y: 700), on: upright), CGPoint(x: 72, y: 92))
        let cropped = try page(cropBox: "[50 400 450 780]")
        XCTAssertEqual(PageGeometry.displayPoint(forPagePoint: CGPoint(x: 50, y: 780), on: cropped), .zero, "the crop box's corner, not the page's")
    }

    /// The real check: paint the page somewhere on a canvas, find where the text landed, and ask which
    /// page point that is. It must be the text's own place on the page, whatever the rotation or crop.
    func testPointUnderTheMouseIsTheRightPlaceOnThePage() throws {
        for (name, page) in try cases() {
            let size = PageRenderer.displaySize(of: page)
            let scale: CGFloat = 0.5
            let frame = CGRect(x: 30, y: 45, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            let width = Int(frame.maxX) + 20, height = Int(frame.maxY) + 20
            var canvas = [UInt8](repeating: 255, count: width * height * 4)
            canvas.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                PageRenderer.draw(page, in: frame, context: context)
            }
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where canvas[(y * width + x) * 4] < 128 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            XCTAssertGreaterThan(maxX, 0, "nothing painted: \(name)")
            let centre = CGPoint(x: CGFloat(minX + maxX) / 2 + 0.5, y: CGFloat(minY + maxY) / 2 + 0.5)
            let onPage = PageGeometry.pagePoint(forCanvasPoint: centre, pageFrame: frame, page: page)
            // "Hello page one" spans roughly x 72–190 and y 696–714 on the page.
            XCTAssertEqual(onPage.x, 131, accuracy: 12, name)
            XCTAssertEqual(onPage.y, 705, accuracy: 8, name)

            // And the other way: the text's box on the page must land on the painted text.
            let landed = PageGeometry.canvasRect(forPageRect: CGRect(x: 72, y: 696, width: 118, height: 18), pageFrame: frame, page: page)
            XCTAssertTrue(landed.insetBy(dx: -6, dy: -6).contains(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)), name)
        }
    }

    func testDegenerateFramesDoNotDivideByZero() throws {
        let page = try page()
        XCTAssertEqual(PageGeometry.pagePoint(forCanvasPoint: CGPoint(x: 5, y: 5), pageFrame: .zero, page: page), .zero)
    }
}
