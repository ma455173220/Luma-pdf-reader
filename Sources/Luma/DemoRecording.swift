import AppKit
import PDFKit
import UniformTypeIdentifiers

/// LUMA_BENCH=demo with LUMA_DEMO=<scene> and LUMA_DEMO_FRAMES=<folder>: plays one of the README's
/// demonstrations and saves the window as a picture fifteen times a second, with a drawn pointer, so
/// that the animations can be made without a hand on the mouse or a screen recording. Time in a scene
/// is counted in pictures, not seconds, so a slow picture does not make the animation jerky.
///
/// Scenes: preview, annotations, pages, magnifier. The document is the first tab;
/// annotations and pages CHANGE it, so give those a copy. LUMA_DEMO_INSERT names the file the pages
/// scene drops in.
enum DemoRecording {
    static let fps = 15.0

    static func run(_ reader: ReaderWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard let scene = env["LUMA_DEMO"], let folder = env["LUMA_DEMO_FRAMES"].map({ URL(fileURLWithPath: $0) }) else {
            print("LUMA_BENCH=demo needs LUMA_DEMO and LUMA_DEMO_FRAMES"); exit(2)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The README shows the light look.
        NSApp.appearance = NSAppearance(named: .aqua)
        let player = Player(reader: reader, folder: folder)
        switch scene {
        case "preview": preview(player)
        case "annotations": annotations(player)
        case "pages": pages(player)
        case "magnifier": magnifier(player)
        default: print("no scene \(scene)"); exit(2)
        }
        // Settled first: pages drawn, decoding ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { player.play() }
    }

    // MARK: Scenes





    /// The previews in one: a citation, a figure and a table, then the table pinned, moved, made
    /// larger, zoomed and its caption selected and copied.
    private static func preview(_ p: Player) {
        let pin = "Pin: stays open when the pointer leaves; drag the top strip to move it, an edge or corner to resize it"
        p.setUp { p.reader.goToPage(1) }
        p.place(link: (2, "21"), at: 0.25)
        p.cursor(at: NSPoint(x: 700, y: 300))
        p.wait(0.4)
        p.named("Rest on a citation") { p.hover(link: (2, "21")); p.wait(1.6) }
        // Text chosen by hand is copied with ⌘C; the two icons take the whole entry the citation
        // names ([21]), selected or not: Google Scholar is searched for that entry.
        p.named("Select text") { p.select(inPanelFrom: CGPoint(x: 0.07, y: 0.07), to: CGPoint(x: 0.92, y: 0.16)) }
        p.caption("⌘C  Copy", seconds: 1.1) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
        p.named("Copy the whole reference [21]") { p.click(toolTip: "Copy this reference", pause: 0.7); p.wait(0.5) }
        p.named("Search Google Scholar for [21]") { p.click(toolTip: "Search Google Scholar for this reference", pause: 0.7); p.wait(0.5) }
        p.caption("Opens in your browser", seconds: 1.0) {}
        p.act { p.reader.debugDismissOverlays() }
        p.named("Rest on a figure") { p.hover(link: (2, "1")); p.wait(1.8) }
        p.act { p.reader.debugDismissOverlays() }
        p.named("Rest on a table") { p.hover(link: (2, "I")); p.wait(1.4) }
        p.named("Pin it") { p.click(toolTip: pin, pause: 0.7) }
        p.wait(0.3)
        p.named("Drag the top to move it") {
            p.drag(within: { p.panelFrame.map { NSPoint(x: $0.midX, y: $0.maxY - 6) } }, by: NSPoint(x: -330, y: 20), seconds: 1.1)
        }
        p.wait(0.3)
        p.named("Drag a corner to resize") {
            p.drag(within: { p.panelFrame.map { NSPoint(x: $0.maxX - 2, y: $0.minY + 2) } }, by: NSPoint(x: 170, y: -130), seconds: 1.1)
        }
        p.wait(0.3)
        p.zoom(steps: 4, factor: 1.05, caption: "⌘ + scroll to zoom in")
        p.wait(0.4)
        p.zoom(steps: 4, factor: 1 / 1.05, caption: "⌘ + scroll to zoom out")
        p.wait(0.6)
    }

    private static func annotations(_ p: Player) {
        var lines: [NSRect] = []
        p.setUp {
            p.reader.goToPage(1)
            lines = p.reader.debugVisibleLines().map { p.reader.debugWindowRect(fromCanvas: $0) }
        }
        func line(_ i: Int) -> NSRect { lines[min(i, lines.count - 1)] }
        // Slow enough to follow: each control is named and pointed at before it is clicked.
        p.cursor(at: NSPoint(x: 700, y: 300))
        p.wait(0.5)
        p.named("Select text") { p.select(line: { line(4) }) }
        p.named("Highlight") { p.click(toolTip: "Highlight", pause: 0.7) }
        p.wait(1.0)
        p.named("Select text") { p.select(line: { line(9) }) }
        p.named("Pick blue") { p.click(toolTip: "Blue", pause: 0.6) }
        p.wait(0.3)
        p.named("Underline") { p.click(toolTip: "Underline", pause: 0.7) }
        p.wait(1.0)
        p.named("Select text") { p.select(line: { line(14) }) }
        p.named("Strikethrough") { p.click(toolTip: "Strikethrough", pause: 0.7) }
        p.wait(1.0)
        p.named("Click a mark to change it") { p.click(at: { NSPoint(x: line(4).minX + line(4).width * 0.4, y: line(4).midY) }, pause: 0.5) }
        p.wait(0.5)
        p.named("Add a note") {
            p.click(toolTip: "Note", pause: 0.7)
            p.type("Check this against Fig. 2")
            p.click(title: "Done", pause: 0.5)
        }
        p.wait(0.6)
        p.caption("⌘S  Save", seconds: 1.4) { p.reader.saveDocument(nil) }
        p.wait(1.0)
    }

    private static func pages(_ p: Player) {
        let insert = ProcessInfo.processInfo.environment["LUMA_DEMO_INSERT"].map { URL(fileURLWithPath: $0) }
        p.setUp { p.reader.showSidebar(.thumbnails) }
        p.cursor(at: NSPoint(x: 700, y: 300))
        p.wait(0.6)
        // Turned from its thumbnail's menu (a menu cannot be drawn into the pictures: a caption names it).
        // The thumbnail's menu is a window of its own, which the pictures cannot hold: it is drawn as
        // the app makes it (the same items in the same order).
        p.named("Right-click a page") {
            p.click(at: { p.reader.debugThumbnailFrame(1).map { NSPoint(x: $0.midX, y: $0.midY) } }, pause: 0.6, by: {
                p.showMenu([L("Rotate Right"), L("Rotate Left"), "-", L("Delete This Page")])
            })
            p.wait(0.6)
        }
        p.named("Choose Rotate Right") {
            p.move(to: { p.menuItemCentre(0) }, seconds: 0.6)
            p.act { p.highlightMenuItem(0) }
            p.wait(0.6)
            p.act { p.flashHere(); p.hideMenu(); p.reader.debugThumbnailActions.turn(1, true) }
            p.wait(1.2)
        }
        p.wait(0.4)
        p.named("Drag a page to move it") {
            p.drag(within: { p.reader.debugThumbnailFrame(0).map { NSPoint(x: $0.midX, y: $0.midY) } },
                   to: { p.reader.debugThumbnailFrame(2).map { NSPoint(x: $0.midX, y: $0.minY - 3) } }, seconds: 1.6)
            p.wait(1.0)
        }
        p.wait(0.4)
        if let insert {
            p.named("Drop a PDF from Finder to insert it") {
                p.dropFile(insert, from: NSPoint(x: 900, y: 260),
                           to: { p.reader.debugThumbnailFrame(2).map { NSPoint(x: $0.midX, y: $0.maxY + 4) } }) {
                    p.reader.debugThumbnailActions.insert([insert], 2)
                }
                p.wait(2.0)
            }
        }
        p.wait(0.5)
    }

    private static func magnifier(_ p: Player) {
        p.setUp { _ = p.reader.debugPlaceLink(onPage: 2, written: "1", atFraction: 0.12) }
        p.cursor(at: NSPoint(x: 820, y: 330))
        p.wait(0.5)
        // Over the figure on the next page, its small labels read through the lens.
        p.act { p.reader.goToPage(2) }
        p.wait(0.4)
        // A toolbar button runs its own tracking loop on a mouse-down, so it is pressed by its action.
        p.named("Turn on the magnifier") {
            p.click(toolTip: "Magnifier", pause: 0.8) { p.reader.toggleMagnifier(nil); p.reader.debugMagnifierPointer(atWindowPoint: NSPoint(x: -100, y: -100)) }
            p.wait(0.4)
        }
        p.named("Move over small print") {
            for target in [NSPoint(x: 260, y: 125), NSPoint(x: 900, y: 125), NSPoint(x: 710, y: 640), NSPoint(x: 900, y: 545), NSPoint(x: 925, y: 350)] {
                p.lens(to: target, seconds: 1.3)
                p.wait(0.5)
            }
        }
        p.caption("Esc  Turn it off", seconds: 1.2) { p.reader.toggleMagnifier(nil) }
        p.wait(0.4)
    }

    // MARK: The player

    /// Runs a scene picture by picture: each step takes a number of pictures and is told how far
    /// through it is, from 0 to 1.
    final class Player {
        let reader: ReaderWindowController
        let folder: URL
        private var steps: [(frames: Int, work: (Double) -> Void)] = []
        private var setUpWork: [() -> Void] = []
        private var pointer = NSPoint(x: 600, y: 400)
        private var pointerImage = NSCursor.arrow
        private var carried: NSImage?
        private var captionText: String?
        /// Pictures left of the ring drawn where a click landed.
        private var flash = 0
        /// A drawn context menu: its items ("-" a separator), top left corner, and the item under the pointer.
        private var menu: (items: [String], corner: NSPoint, highlighted: Int?)?
        private static let menuWidth: CGFloat = 170, menuRow: CGFloat = 22, menuGap: CGFloat = 11, menuPad: CGFloat = 5
        private var frame = 0
        private let writer = DispatchQueue(label: "demo-pictures")
        private weak var pressed: NSView?

        init(reader: ReaderWindowController, folder: URL) {
            self.reader = reader
            self.folder = folder
        }

        // Building a scene.

        func setUp(_ work: @escaping () -> Void) { setUpWork.append(work) }

        func place(link: (Int, String), at fraction: CGFloat) {
            setUp { _ = self.reader.debugPlaceLink(onPage: link.0, written: link.1, atFraction: fraction) }
        }

        func cursor(at point: NSPoint) { act { self.pointer = point } }

        func act(_ work: @escaping () -> Void) { steps.append((0, { _ in work() })) }

        func wait(_ seconds: Double) { steps.append((Int(seconds * fps), { _ in })) }

        /// Glides the pointer to a point worked out when the step begins.
        func move(to target: @escaping () -> NSPoint?, seconds: Double = 0.7) {
            var start = NSPoint.zero, end = NSPoint.zero
            steps.append((max(1, Int(seconds * fps)), { t in
                if t == 0 { start = self.pointer; end = target() ?? start }
                let e = t * t * (3 - 2 * t)
                self.pointer = NSPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e)
            }))
        }

        func move(by delta: NSPoint, seconds: Double) {
            var end = NSPoint.zero
            act { end = NSPoint(x: self.pointer.x + delta.x, y: self.pointer.y + delta.y) }
            move(to: { end }, seconds: seconds)
        }

        /// The pointer goes to the link and rests there; the preview shows as resting does.
        func hover(link: (Int, String)) {
            var rect: NSRect?
            act { rect = self.linkRect(link) }
            move(to: { rect.map { NSPoint(x: $0.midX, y: $0.midY) } })
            act { if let rect { self.reader.debugShowPreview(atWindowPoint: NSPoint(x: rect.midX, y: rect.midY)) } }
        }

        private func linkRect(_ link: (Int, String)) -> NSRect? {
            reader.debugPlaceLink(onPage: link.0, written: link.1, atFraction: nil)
        }

        func click(toolTip: String, pause: Double = 0, by action: (() -> Void)? = nil) {
            move(to: { self.view(toolTip: toolTip).map { self.centre(of: $0) } }, seconds: 0.5)
            if pause > 0 { wait(pause) }
            act {
                self.flash = 6
                if let action { return action() }
                guard let view = self.view(toolTip: toolTip) else { return print("  (no control \"\(toolTip)\")") }
                self.press(view)
            }
            wait(0.25)
        }

        func click(title: String, pause: Double = 0) {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.title == L(title) { return b }
                for sub in v.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            move(to: { self.root.flatMap(find).map { self.centre(of: $0) } }, seconds: 0.5)
            if pause > 0 { wait(pause) }
            act { self.flash = 6; self.root.flatMap(find)?.performClick(nil) }
            wait(0.25)
        }

        func click(at point: @escaping () -> NSPoint?, pause: Double = 0, by action: (() -> Void)? = nil) {
            move(to: point, seconds: 0.5)
            if pause > 0 { wait(pause) }
            act {
                self.flash = 6
                if let action { return action() }
                self.send(.leftMouseDown, at: self.pointer)
                self.send(.leftMouseUp, at: self.pointer)
            }
            wait(0.25)
        }

        /// Drags from a point worked out when the step begins, by a distance, with mouse events.
        func drag(within start: @escaping () -> NSPoint?, by delta: NSPoint, seconds: Double) {
            var from = NSPoint.zero
            drag(within: start, to: { NSPoint(x: from.x + delta.x, y: from.y + delta.y) }, seconds: seconds, startAt: { from = $0 })
        }

        func drag(within start: @escaping () -> NSPoint?, to end: @escaping () -> NSPoint?, seconds: Double, startAt: ((NSPoint) -> Void)? = nil) {
            move(to: start, seconds: 0.6)
            var from = NSPoint.zero, to = NSPoint.zero
            act {
                from = self.pointer
                startAt?(from)
                to = end() ?? from
                self.pointerImage = .closedHand
                self.flash = 6
                self.send(.leftMouseDown, at: from)
            }
            steps.append((max(2, Int(seconds * fps)), { t in
                let e = t * t * (3 - 2 * t)
                self.pointer = NSPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
                self.send(.leftMouseDragged, at: self.pointer)
            }))
            act {
                self.send(.leftMouseDragged, at: to)
                self.pointer = to
                self.send(.leftMouseUp, at: to)
                self.pointerImage = .arrow
            }
        }

        /// Selects a line of the page by dragging across it.
        func select(line: @escaping () -> NSRect) {
            drag(within: { NSPoint(x: line().minX + 1, y: line().midY) }, to: { NSPoint(x: line().maxX - 1, y: line().midY) }, seconds: 0.9)
            act { self.pointerImage = .arrow }
            wait(0.3)
        }

        /// Selects text in the pinned preview, between two places given as fractions of it (from its top left).
        func select(inPanelFrom a: CGPoint, to b: CGPoint) {
            func at(_ f: CGPoint) -> NSPoint? { panelFrame.map { NSPoint(x: $0.minX + $0.width * f.x, y: $0.maxY - $0.height * f.y) } }
            drag(within: { at(a) }, to: { at(b) }, seconds: 1.0)
            act { self.pointerImage = .arrow }
            wait(0.3)
        }

        func zoom(steps count: Int, factor: CGFloat, caption text: String) {
            move(to: { self.panelFrame.map { NSPoint(x: $0.midX, y: $0.midY) } }, seconds: 0.5)
            act { self.captionText = text }
            wait(0.4)
            for _ in 0..<count {
                act { _ = self.reader.debugZoomPinned(by: factor) }
                wait(0.2)
            }
            wait(0.3)
            act { self.captionText = nil }
        }

        /// Glides the pointer, the magnifier's lens following it.
        func lens(to target: NSPoint, seconds: Double) {
            move(to: { target }, seconds: seconds)
            let glide = steps.removeLast()
            steps.append((glide.frames, { t in
                glide.work(t)
                self.reader.debugMagnifierPointer(atWindowPoint: self.pointer)
            }))
        }

        func showMenu(_ items: [String]) { menu = (items, NSPoint(x: pointer.x + 2, y: pointer.y - 2), nil) }
        func hideMenu() { menu = nil }
        func highlightMenuItem(_ index: Int) { menu?.highlighted = index }
        func flashHere() { flash = 6 }

        /// The middle of item `index` of the drawn menu, in window coordinates.
        func menuItemCentre(_ index: Int) -> NSPoint? {
            guard let menu, let frame = menuItemFrames(menu).first(where: { $0.index == index })?.frame else { return nil }
            return NSPoint(x: frame.minX + 40, y: frame.midY)
        }

        private func menuItemFrames(_ menu: (items: [String], corner: NSPoint, highlighted: Int?)) -> [(index: Int, frame: NSRect)] {
            var y = menu.corner.y - Player.menuPad
            var frames: [(Int, NSRect)] = []
            for (k, item) in menu.items.enumerated() {
                let h = item == "-" ? Player.menuGap : Player.menuRow
                frames.append((k, NSRect(x: menu.corner.x, y: y - h, width: Player.menuWidth, height: h)))
                y -= h
            }
            return frames
        }

        private func drawMenu(in view: NSView) {
            guard let menu else { return }
            let frames = menuItemFrames(menu)
            let height = frames.reduce(0) { $0 + $1.frame.height } + 2 * Player.menuPad
            let box = view.convert(NSRect(x: menu.corner.x, y: menu.corner.y - height, width: Player.menuWidth, height: height), from: nil)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            NSColor(white: 0.96, alpha: 0.98).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).stroke()
            for (index, frame) in frames {
                let rect = view.convert(frame, from: nil)
                let item = menu.items[index]
                if item == "-" {
                    NSColor.black.withAlphaComponent(0.12).setFill()
                    NSRect(x: rect.minX + 10, y: rect.midY, width: rect.width - 20, height: 1).fill()
                    continue
                }
                let lit = menu.highlighted == index
                if lit {
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
                }
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: lit ? NSColor.white : NSColor.labelColor]
                let size = (item as NSString).size(withAttributes: attributes)
                (item as NSString).draw(at: NSPoint(x: rect.minX + 14, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }

        /// Names what the steps built by `build` do, in a caption shown while they run.
        func named(_ label: String, _ build: () -> Void) {
            act { self.captionText = label }
            build()
            act { self.captionText = nil }
        }

        func caption(_ text: String, seconds: Double, _ work: @escaping () -> Void) {
            act { self.captionText = text; work() }
            wait(seconds)
            act { self.captionText = nil }
        }

        /// Types into the text view that has the keyboard, a letter at a time.
        func type(_ text: String) {
            wait(0.3)
            for k in 1...text.count {
                act { (self.reader.window.firstResponder as? NSTextView)?.string = String(text.prefix(k)) }
                steps.append((2, { _ in }))
            }
            wait(0.4)
        }

        /// Carries a file's icon from outside the window to a place in it, and drops it there.
        func dropFile(_ url: URL, from start: NSPoint, to end: @escaping () -> NSPoint?, _ drop: @escaping () -> Void) {
            act {
                self.pointer = start
                // The plain PDF document icon, not the icon of whichever app opens PDFs here.
                let icon = NSWorkspace.shared.icon(for: .pdf)
                icon.size = NSSize(width: 56, height: 56)
                self.carried = icon
            }
            move(to: end, seconds: 1.4)
            wait(0.3)
            act { self.carried = nil; drop() }
        }

        // Playing it.

        func play() {
            // In front, so that the window and its selections are drawn as the reader sees them.
            NSApp.activate(ignoringOtherApps: true)
            reader.window.makeKeyAndOrderFront(nil)
            setUpWork.forEach { $0() }
            var index = 0, within = 0
            func tick() {
                while index < steps.count && steps[index].frames == 0 {
                    steps[index].work(0)
                    index += 1
                }
                guard index < steps.count else {
                    writer.sync {}
                    print("demo: \(frame) pictures in \(folder.path)")
                    exit(0)
                }
                let step = steps[index]
                step.work(Double(within) / Double(max(1, step.frames - 1)))
                within += 1
                if within >= step.frames { index += 1; within = 0 }
                // The window draws what changed before the picture is taken.
                DispatchQueue.main.async {
                    self.picture()
                    DispatchQueue.main.async(execute: tick)
                }
            }
            tick()
        }

        private func picture() {
            guard let view = reader.window.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let inView = view.convert(pointer, from: nil)
            if let carried {
                carried.draw(in: NSRect(x: inView.x - 10, y: inView.y - 50, width: 56, height: 56), from: .zero, operation: .sourceOver, fraction: 0.85)
            }
            drawMenu(in: view)
            if flash > 0 {
                // A ring that widens and fades where the click landed.
                let r = 10 + CGFloat(6 - flash) * 4
                NSColor.systemOrange.withAlphaComponent(0.25 + 0.1 * CGFloat(flash)).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: inView.x - r, y: inView.y - r, width: 2 * r, height: 2 * r))
                ring.lineWidth = 3
                ring.stroke()
                flash -= 1
            }
            let image = pointerImage.image, hot = pointerImage.hotSpot
            image.draw(in: NSRect(x: inView.x - hot.x, y: inView.y - (image.size.height - hot.y), width: image.size.width, height: image.size.height))
            if let captionText { drawCaption(captionText, in: view.bounds) }
            NSGraphicsContext.restoreGraphicsState()
            let number = frame
            frame += 1
            let url = folder.appendingPathComponent(String(format: "f%04d.png", number))
            writer.async { try? rep.representation(using: .png, properties: [:])?.write(to: url) }
        }

        private func drawCaption(_ text: String, in bounds: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attributes)
            let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.minY + 28, width: size.width + 32, height: size.height + 14)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            (text as NSString).draw(at: NSPoint(x: box.minX + 16, y: box.minY + 7), withAttributes: attributes)
        }

        // Finding things in the window.

        private var root: NSView? { reader.window.contentView?.superview }

        var panelFrame: NSRect? {
            func find(_ v: NSView) -> FloatingPanelView? {
                if let p = v as? FloatingPanelView, p.content is PreviewPopupView { return p }
                for sub in v.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return root.flatMap(find).map { $0.convert($0.bounds, to: nil) }
        }

        private func view(toolTip: String) -> NSView? {
            func find(_ v: NSView) -> NSView? {
                if !v.isHidden, v.toolTip == L(toolTip) { return v }
                for sub in v.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return root.flatMap(find)
        }

        private func centre(of view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }

        private func press(_ view: NSView) {
            if let button = view as? NSButton { button.performClick(nil); return }
            let point = centre(of: view)
            send(.leftMouseDown, at: point)
            send(.leftMouseUp, at: point)
        }

        /// Hands a mouse event to the view under it, as the window would (the app may be behind
        /// others, where the window's own routing would swallow the first click).
        private func send(_ type: NSEvent.EventType, at point: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: reader.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            if type == .leftMouseDown { pressed = root?.hitTest(point) }
            guard let target = pressed else { return }
            switch type {
            case .leftMouseDown: target.mouseDown(with: event)
            case .leftMouseDragged: target.mouseDragged(with: event)
            case .leftMouseUp: target.mouseUp(with: event)
            default: break
            }
        }
    }
}
