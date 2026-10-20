import CoreGraphics
import Foundation

/// One line of marked text: four corners in page coordinates, in the order PDF uses for
/// QuadPoints — top-left, top-right, bottom-left, bottom-right.
public struct MarkupQuad: Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomLeft: CGPoint
    public var bottomRight: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// An upright line of text occupying `rect`.
    public init(_ rect: CGRect) {
        self.init(topLeft: CGPoint(x: rect.minX, y: rect.maxY), topRight: CGPoint(x: rect.maxX, y: rect.maxY),
                  bottomLeft: CGPoint(x: rect.minX, y: rect.minY), bottomRight: CGPoint(x: rect.maxX, y: rect.minY))
    }

    var points: [CGPoint] { [topLeft, topRight, bottomLeft, bottomRight] }

    /// Reads quads from a flat list of numbers (eight per quad). Nil when the list is unusable.
    static func quads(from numbers: [Double]) -> [MarkupQuad]? {
        guard !numbers.isEmpty, numbers.count % 8 == 0, numbers.allSatisfy({ $0.isFinite }) else { return nil }
        return stride(from: 0, to: numbers.count, by: 8).map { i in
            MarkupQuad(topLeft: CGPoint(x: numbers[i], y: numbers[i + 1]), topRight: CGPoint(x: numbers[i + 2], y: numbers[i + 3]),
                       bottomLeft: CGPoint(x: numbers[i + 4], y: numbers[i + 5]), bottomRight: CGPoint(x: numbers[i + 6], y: numbers[i + 7]))
        }
    }
}

/// How a highlight, underline or strikethrough is drawn, written into the file with it, so that every reader shows
/// it the same way instead of each improvising its own.
public enum MarkupAppearance {
    public struct Drawing: Equatable {
        /// The area the drawing covers, in page coordinates; also the annotation's rectangle.
        public let bounds: CGRect
        /// The drawing itself, in PDF's page-description language.
        public let content: String
        /// Whether the colour is multiplied into the page (highlight) rather than painted over it.
        public let multiplies: Bool
    }

    static func number(_ value: CGFloat) -> String {
        // Three decimals are far finer than a printed dot; trailing zeros are trimmed to keep files small.
        var text = String(format: "%.3f", Double(value))
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// Whether every number is one a page can hold: finite, and no further out than a million points.
    static func usable(_ numbers: [CGFloat]) -> Bool {
        numbers.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
    }

    /// The upright box around a quad. Files list a quad's corners in more than one order, so the box,
    /// not the order, says where the line is.
    static func box(_ quad: MarkupQuad) -> CGRect {
        let xs = quad.points.map(\.x), ys = quad.points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// How far the order of a quad's corners can be believed.
    public enum Corners {
        /// Named as the text reads, top-left first, the way the reader's own marks are made: an
        /// underline goes along the bottom edge they name, whichever way the text runs on the page.
        case asTheTextReads
        /// Read from a file, where programs list corners in more than one order: believed only when
        /// they describe an ordinary line, read along its longer side and not upside down on the page
        /// as shown; otherwise each line's box and the page's turn decide where the bottom is.
        case fromAFile
    }

    /// A line's bottom edge as its text reads, the way up from it and its height, when the quad's
    /// corners describe a line: top and bottom edges running the same way, the sides square to them.
    static func readingEdge(of quad: MarkupQuad, corners: Corners, rotation: Int) -> (from: CGPoint, to: CGPoint, up: CGVector, height: CGFloat)? {
        let along = CGVector(dx: quad.topRight.x - quad.topLeft.x, dy: quad.topRight.y - quad.topLeft.y)
        let alongBelow = CGVector(dx: quad.bottomRight.x - quad.bottomLeft.x, dy: quad.bottomRight.y - quad.bottomLeft.y)
        let up = CGVector(dx: quad.topLeft.x - quad.bottomLeft.x, dy: quad.topLeft.y - quad.bottomLeft.y)
        let length = hypot(along.dx, along.dy), height = hypot(up.dx, up.dy)
        guard length > 0, height > 0, hypot(along.dx - alongBelow.dx, along.dy - alongBelow.dy) <= 0.1 * length,
              abs(along.dx * up.dx + along.dy * up.dy) <= 0.1 * length * height else { return nil }
        if corners == .fromAFile {
            let shownUp: CGVector
            switch ((rotation % 360) + 360) % 360 {
            case 90: shownUp = CGVector(dx: -1, dy: 0)
            case 180: shownUp = CGVector(dx: 0, dy: -1)
            case 270: shownUp = CGVector(dx: 1, dy: 0)
            default: shownUp = CGVector(dx: 0, dy: 1)
            }
            guard length >= height, up.dx * shownUp.dx + up.dy * shownUp.dy > -0.7 * height else { return nil }
        }
        return (quad.bottomLeft, quad.bottomRight, CGVector(dx: up.dx / height, dy: up.dy / height), height)
    }

    /// - Parameters:
    ///   - rotation: the page's turn (0, 90, 180 or 270): where the corners do not say which way the
    ///     text reads, an underline goes under the text as the page is shown, which on a turned page
    ///     is another edge of each line's box.
    ///   - frame: the area the drawing is declared to cover; by default, the lines and the underlines.
    ///     A changed mark keeps its own rectangle, so that its drawing is not stretched to fit.
    ///   - corners: how far the order of the quads' corners can be believed.
    public static func drawing(kind: MarkupAddition.Kind, quads: [MarkupQuad], red: Double, green: Double, blue: Double,
                               rotation: Int = 0, frame: CGRect? = nil, corners: Corners = .fromAFile) -> Drawing {
        func c(_ v: Double) -> String { number(CGFloat(min(max(v, 0), 1))) }
        let boxes = quads.map(box)
        guard let first = boxes.first else { return Drawing(bounds: frame ?? .zero, content: "", multiplies: false) }
        var bounds = boxes.dropFirst().reduce(first) { $0.union($1) }
        var lines: [String] = []
        switch kind {
        case .highlight:
            lines.append("/GS0 gs")
            lines.append("\(c(red)) \(c(green)) \(c(blue)) rg")
            for b in boxes { lines.append("\(number(b.minX)) \(number(b.minY)) \(number(b.width)) \(number(b.height)) re") }
            lines.append("f")
        case .underline, .strikeOut:
            // A line a little inside the bottom edge of the text (through its middle for a
            // strikethrough), as thick as a fraction of the line's height. Where the corners do not
            // say which edge is the bottom, the edge at the bottom as the page is shown.
            let rise: CGFloat = kind == .strikeOut ? 0.45 : 0.1
            lines.append("\(c(red)) \(c(green)) \(c(blue)) RG")
            var thickest: CGFloat = 0
            let turn = ((rotation % 360) + 360) % 360
            for (quad, b) in zip(quads, boxes) {
                if let edge = readingEdge(of: quad, corners: corners, rotation: turn) {
                    let width = max(0.5, edge.height * 0.07)
                    thickest = max(thickest, width)
                    let lift = edge.height * rise
                    let from = CGPoint(x: edge.from.x + edge.up.dx * lift, y: edge.from.y + edge.up.dy * lift)
                    let to = CGPoint(x: edge.to.x + edge.up.dx * lift, y: edge.to.y + edge.up.dy * lift)
                    lines.append("\(number(width)) w \(number(from.x)) \(number(from.y)) m \(number(to.x)) \(number(to.y)) l S")
                    continue
                }
                // The box's height and width as the page is shown.
                let tall = turn == 90 || turn == 270 ? b.width : b.height
                let wide = turn == 90 || turn == 270 ? b.height : b.width
                let (from, to): (CGPoint, CGPoint)
                let width: CGFloat
                if tall > wide * 3 && tall > 40 {
                    // A long column, which no single upright character makes: text running up the
                    // page, the way most turned text in a document reads, so the line runs along the
                    // side its letters stand on, the right as shown.
                    width = max(0.5, wide * 0.07)
                    let lift = wide * rise
                    switch turn {
                    case 90: (from, to) = (CGPoint(x: b.minX, y: b.maxY - lift), CGPoint(x: b.maxX, y: b.maxY - lift))
                    case 180: (from, to) = (CGPoint(x: b.minX + lift, y: b.minY), CGPoint(x: b.minX + lift, y: b.maxY))
                    case 270: (from, to) = (CGPoint(x: b.minX, y: b.minY + lift), CGPoint(x: b.maxX, y: b.minY + lift))
                    default: (from, to) = (CGPoint(x: b.maxX - lift, y: b.minY), CGPoint(x: b.maxX - lift, y: b.maxY))
                    }
                } else {
                    // Under the line as shown; a single tall character does not make it thick.
                    let height = min(tall, wide)
                    width = max(0.5, height * 0.07)
                    let lift = height * rise
                    switch turn {
                    case 90: (from, to) = (CGPoint(x: b.maxX - lift, y: b.minY), CGPoint(x: b.maxX - lift, y: b.maxY))
                    case 180: (from, to) = (CGPoint(x: b.minX, y: b.maxY - lift), CGPoint(x: b.maxX, y: b.maxY - lift))
                    case 270: (from, to) = (CGPoint(x: b.minX + lift, y: b.minY), CGPoint(x: b.minX + lift, y: b.maxY))
                    default: (from, to) = (CGPoint(x: b.minX, y: b.minY + lift), CGPoint(x: b.maxX, y: b.minY + lift))
                    }
                }
                thickest = max(thickest, width)
                lines.append("\(number(width)) w \(number(from.x)) \(number(from.y)) m \(number(to.x)) \(number(to.y)) l S")
            }
            bounds = bounds.insetBy(dx: -thickest, dy: -thickest)
        }
        return Drawing(bounds: frame ?? bounds, content: lines.joined(separator: "\n"), multiplies: kind == .highlight)
    }
}
