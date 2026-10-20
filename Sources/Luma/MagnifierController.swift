import AppKit
import LumaCore
import PDFKit

/// The lens itself: it repaints the part of the document under its centre, enlarged, straight from
/// the PDF, so that what it shows is sharp rather than a blown-up copy of the screen.
private final class LensView: NSView {
    weak var canvas: PageCanvasView?
    /// The canvas point the lens is centred on.
    var centre = NSPoint.zero { didSet { needsDisplay = true } }
    var magnification: CGFloat = 3

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()
        guard let canvas, let document = canvas.document, let context = NSGraphicsContext.current?.cgContext else { return }
        // The strip of canvas that fits in the lens at this magnification.
        let region = CGRect(x: centre.x - bounds.width / (2 * magnification), y: centre.y - bounds.height / (2 * magnification),
                            width: bounds.width / magnification, height: bounds.height / magnification)
        for index in canvas.layout.pages(intersecting: region) {
            guard let page = document.page(at: index) else { continue }
            let frame = canvas.layout.frames[index]
            let enlarged = CGRect(x: (frame.minX - region.minX) * magnification, y: (frame.minY - region.minY) * magnification,
                                  width: frame.width * magnification, height: frame.height * magnification)
            PageRenderer.draw(page, in: enlarged, context: context)
        }
    }
}

/// The magnifier: a mode in which a lens follows the pointer and shows the page beneath it enlarged.
final class MagnifierController {
    /// Starting values; the reader tunes them after trying.
    static let lensSize = CGSize(width: 480, height: 300)
    static let magnification: CGFloat = 3

    private weak var host: NSView?
    private weak var scrollView: NSScrollView?
    private weak var canvas: PageCanvasView?

    private(set) var isOn = false
    private var panel: FloatingPanelView?
    private var lens: LensView?

    init(host: NSView, scrollView: NSScrollView, canvas: PageCanvasView) {
        self.host = host
        self.scrollView = scrollView
        self.canvas = canvas
    }

    var isShowingLens: Bool { panel != nil }

    func setOn(_ on: Bool) {
        isOn = on
        if on { refresh() } else { removeLens() }
    }

    /// Call with the pointer's place on the canvas, or nil when it has left.
    func pointerMoved(to point: NSPoint?) {
        guard isOn, let host, let scrollView, let canvas, canvas.document != nil, let point, canvas.visibleRect.contains(point) else {
            removeLens()
            return
        }
        NSCursor.crosshair.set()
        let viewport = scrollView.frame.size
        let size = CGSize(width: min(MagnifierController.lensSize.width, viewport.width * 0.8),
                          height: min(MagnifierController.lensSize.height, viewport.height * 0.8))
        let centreInHost = host.convert(point, from: canvas)
        let frame = NSRect(x: centreInHost.x - size.width / 2, y: centreInHost.y - size.height / 2, width: size.width, height: size.height)
        if panel == nil {
            let view = LensView(frame: NSRect(origin: .zero, size: size))
            view.canvas = canvas
            view.magnification = MagnifierController.magnification
            let newPanel = FloatingPanelView(frame: frame, content: view)
            newPanel.letsEventsThrough = true
            host.addSubview(newPanel)
            panel = newPanel
            lens = view
        }
        panel?.frame = frame
        lens?.centre = point
    }

    /// The page moved or changed size under a pointer that stayed still.
    func refresh() {
        guard isOn, let canvas, let window = canvas.window else { return }
        pointerMoved(to: canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func removeLens() {
        panel?.removeFromSuperview()
        panel = nil
        lens = nil
    }
}
