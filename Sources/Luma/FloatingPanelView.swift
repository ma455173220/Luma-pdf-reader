import AppKit

/// A small panel that floats above the page: rounded corners, a hairline edge, a soft shadow.
/// Used for the hover preview and for the magnifier's lens.
final class FloatingPanelView: NSView {
    let content: NSView
    /// A panel that only shows something (the lens) must not swallow clicks or scrolling meant for the page.
    var letsEventsThrough = false

    init(frame: NSRect, content: NSView) {
        self.content = content
        super.init(frame: frame)
        // The panel is white like the pages, in dark mode too, so its icons and text stay dark.
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        content.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        letsEventsThrough ? nil : super.hitTest(point)
    }
}
