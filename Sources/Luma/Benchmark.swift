import AppKit
import LumaCore
import Foundation
import PDFKit

/// Memory measurement for ADR 0003, switched on by the LUMA_BENCH environment variable.
/// It drives the app the way the protocol describes, prints the readings, and quits.
///
///   LUMA_BENCH=single  one document: readings after 15 s and 60 s, then a scroll through and two more readings
///   LUMA_BENCH=paging  one document: a reading at rest, then every page shown in turn and back again,
///                      half a second each, then two more readings. The same steps can be scripted
///                      in Skim, which makes this the mode to use when comparing the two.
///   LUMA_BENCH=tabs    several documents: shows each tab in turn, then one reading
///   LUMA_BENCH=sleep   several documents: pages through each tab in turn, a reading; puts the background
///                      tabs to sleep, a reading; wakes the first (left on its third page), a reading
///   LUMA_BENCH=sidebar one document: readings with the sidebar showing thumbnails, then the outline, then
///                      folded away again; then during and after a search for a common word
///   LUMA_BENCH=marks   one document, which it CHANGES: selects text with real mouse events, marks it,
///                      saves, changes and deletes marks, saves again. Only ever give it a copy.
///   LUMA_BENCH=pages   one document, which it CHANGES: from the thumbnails, turns a page, takes one out,
///                      drags one with mouse events, inserts the file LUMA_INSERT (another PDF), undoes and
///                      redoes, with LUMA_SAVE_AS=<path> saves as that new file (the original left as it was),
///                      saves, and reads the file the tab shows afresh.
///                      Only ever give it a copy.
///   LUMA_BENCH=extras  one document, which it CHANGES and REPLACES: copying, typing a page number, saving
///                      after another program changed the file, and reloading. Only ever give it a copy
///                      (with LUMA_EXTRAS_ORIGINAL naming another copy, and LUMA_ANSWERS=keep,reload).
///   LUMA_BENCH=everything one document, which it CHANGES: every feature used once in a row (paging, sidebar,
///                      search, marks and a save, copying), with readings along the way. Only ever give it a copy.
///   LUMA_BENCH=outline one document: readings at rest, with the outline showing (worked out from the
///                      text when the document has none) and after the sidebar is put away
///   LUMA_BENCH=previews one document: the preview of each link named in LUMA_PREVIEW_LINKS, a
///                      snapshot of each
///   LUMA_BENCH=refresh one document paged through and searched, then read afresh in front (or not,
///                      with LUMA_REFRESH_CONTROL): readings before and after
///   LUMA_BENCH=figures one document that links its own citations: readings before anything, with a
///                      preview of a figure from three places in turn, and after its own reading
///                      document is let go
///   LUMA_BENCH=pin     one document: readings before anything, with a hover preview, with it pinned,
///                      with a second pinned in its place, and after unpinning (LUMA_BENCH_PAGE as below)
///   LUMA_BENCH=overlays one document: readings before, during and after a hover preview, and before,
///                      during and after sweeping the magnifier across the page. LUMA_BENCH_PAGE=n starts
///                      on page n instead of the middle; LUMA_HOVER_TEXT=… points at the first place in
///                      view where that text is written instead of at the first link
enum Benchmark {
    /// The process's own phys_footprint: the same figure `footprint -p` gives from outside at the same
    /// moment, measured to agree within 0.1 MB at every step of the pin walk-through on both screens
    /// (ADR 0005). scripts/footprint-walk.sh reads `footprint -p` alongside, to keep checking that.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func report(_ label: String) {
        print(String(format: "  %@: %.1f MB", label, footprintMB()))
        fflush(stdout)
        // LUMA_BENCH_HOLD=s: holds still for s seconds after each reading, so that `footprint -p`
        // from outside reads the same moment.
        if let hold = ProcessInfo.processInfo.environment["LUMA_BENCH_HOLD"].flatMap(Double.init) {
            Thread.sleep(forTimeInterval: hold)
        }
    }

    private static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static var isRequested: Bool { ProcessInfo.processInfo.environment["LUMA_BENCH"] != nil }

    /// Where a walk-through's window goes: on the second display when there is one, so that it does
    /// not flash over the reader's work on the main one (LUMA_BENCH_SCREEN=main puts it there
    /// instead: memory readings depend on the display's scale, and the protocol's readings were
    /// taken on the main, Retina, display). The protocol's window is 1200×900 points of content;
    /// LUMA_BENCH_SIZE=WxH asks for another size. Either is made smaller to fit the display.
    static func placeWindow(_ window: NSWindow) {
        let screens = NSScreen.screens
        let onMain = ProcessInfo.processInfo.environment["LUMA_BENCH_SCREEN"] == "main"
        guard let screen = (onMain ? screens.first : screens.dropFirst().first ?? screens.first) else { return }
        let requested = (ProcessInfo.processInfo.environment["LUMA_BENCH_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        var content = requested.count == 2 ? NSSize(width: requested[0], height: requested[1]) : NSSize(width: 1200, height: 900)
        let visible = screen.visibleFrame
        let chrome = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        content.width -= max(0, chrome.width - visible.width)
        content.height -= max(0, chrome.height - visible.height)
        window.setContentSize(content)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
    }

    /// LUMA_ANSWERS=save,discard,cancel: in a walk-through, the answers to the questions asked
    /// before closing, in turn, so that closing can be walked through without a hand on the mouse.
    private static var scriptedAnswers = (ProcessInfo.processInfo.environment["LUMA_ANSWERS"] ?? "")
        .split(separator: ",").map(String.init)
    static func nextScriptedAnswer() -> String? {
        guard isRequested, !scriptedAnswers.isEmpty else { return nil }
        return scriptedAnswers.removeFirst()
    }

    static func startIfRequested(_ reader: ReaderWindowController) {
        guard let mode = ProcessInfo.processInfo.environment["LUMA_BENCH"] else { return }
        guard ["single", "outline", "paging", "tabs", "tour", "overlays", "sidebar", "marks", "pages", "pagesclose", "sleep", "pin", "figures", "refresh", "previews", "search", "extras", "closing", "everything", "demo"].contains(mode) else {
            print("LUMA_BENCH=\(mode) is not a mode. Use single, outline, paging, tabs, tour, overlays, sidebar, marks, pages, pagesclose, sleep, pin, figures, refresh, previews, search, extras, closing or everything.")
            exit(2)
        }
        // Documents are read in the background; nothing can be measured until they are all open.
        guard !reader.isLoading else {
            after(0.1) { startIfRequested(reader) }
            return
        }
        placeWindow(reader.window)
        let content = reader.window.contentView?.bounds.size ?? .zero
        print("bench=\(mode) documents=\(reader.sessions.count) content=\(Int(content.width))x\(Int(content.height))pt scale=\(reader.window.backingScaleFactor)")

        if mode == "tour" {
            tour(reader)
            return
        }

        if mode == "demo" {
            DemoRecording.run(reader)
            return
        }

        if mode == "marks" {
            marks(reader)
            return
        }

        if mode == "pages" {
            pages(reader)
            return
        }

        if mode == "pagesclose" {
            // One document, which it CHANGES: turns its first page, then closes the tab answering
            // 保存 (LUMA_ANSWERS=save). The tab must close and the file must hold the turn.
            after(3) {
                reader.showSidebar(.thumbnails)
                reader.debugThumbnailActions.turn(0, true)
                let url = reader.sessions.first?.url
                reader.close(0)
                let turn = url.flatMap { PDFDocument(url: $0)?.page(at: 0)?.rotation } ?? -1
                print("  after closing with Save: tabs open \(reader.sessions.count), first page of the file turned \(turn)")
                exit(0)
            }
            return
        }

        if mode == "extras" {
            extras(reader)
            return
        }

        if mode == "closing" {
            closing(reader)
            return
        }

        if mode == "everything" {
            everything(reader)
            return
        }

        if mode == "sidebar" {
            // Show every page once first, so that what the sidebar adds can be told apart from what
            // merely looking at more pages adds.
            let count = reader.currentPageCount
            for index in 0..<count { after(0.25 * Double(index)) { reader.goToPage(index) } }
            after(0.25 * Double(count)) { reader.goToPage(0) }
            after(0.25 * Double(count) + 15) {
                report("after every page has been shown once")
                reader.showSidebar(.thumbnails)
                after(8) {
                    report("sidebar showing thumbnails")
                    reader.showSidebar(.outline)
                    after(8) {
                        snapshot(reader, "sidebar-outline")
                        report("sidebar showing the outline")
                        reader.debugHideSidebar()
                        after(8) {
                            report("sidebar folded away")
                            // LUMA_BENCH_QUERY picks the word; one that is not in the document makes the
                            // engine read every page without leaving any matches to keep.
                            reader.debugSearch(for: ProcessInfo.processInfo.environment["LUMA_BENCH_QUERY"] ?? "the")
                            after(12) {
                                print("  (\(reader.debugSearch))")
                                report("search results on show")
                                reader.debugCloseSearch()
                                after(10) { report("search closed, 10 s later"); exit(0) }
                            }
                        }
                    }
                }
            }
            return
        }

        if mode == "outline" {
            // The outline view on its own: at rest, while the outline shows, and after it is put away.
            after(15) {
                report("at rest")
                reader.showSidebar(.outline)
                after(10) {
                    snapshot(reader, "outline")
                    report("outline showing, 10 s later")
                    // LUMA_OUTLINE_PICK: entries to click in turn, by the start of their titles ("5.1|5.2").
                    let picks = (ProcessInfo.processInfo.environment["LUMA_OUTLINE_PICK"] ?? "").split(separator: "|")
                    for (i, pick) in picks.enumerated() {
                        after(Double(i) * 1.5) { print("  (\(reader.debugClickOutline(String(pick))))") }
                        after(Double(i) * 1.5 + 1) {
                            print("  (1 s later, marked \"\(reader.debugOutlineCurrent)\")")
                            reader.debugNudge()
                            print("  (scrolled a little, marked \"\(reader.debugOutlineCurrent)\")")
                        }
                    }
                    after(Double(picks.count) * 1.5) {
                        reader.debugHideSidebar()
                        after(10) { report("sidebar folded away, 10 s later"); exit(0) }
                    }
                }
            }
            return
        }

        if mode == "search" {
            // LUMA_SEARCH=text: the same search with each setting of the find bar's two options, the
            // count each gives, a snapshot of each, and memory before and after.
            let query = ProcessInfo.processInfo.environment["LUMA_SEARCH"] ?? "band"
            let settings = [SearchOptions(), SearchOptions(matchCase: true), SearchOptions(wholeWords: true), SearchOptions(matchCase: true, wholeWords: true)]
            func run(_ k: Int) {
                guard k < settings.count else {
                    reader.debugCloseSearch()
                    after(10) { report("search bar closed, 10 s later"); exit(0) }
                    return
                }
                reader.debugSearch(for: query, options: settings[k])
                func wait() {
                    if reader.debugIsSearching { return after(0.5) { wait() } }
                    print("  (\"\(query)\" match case \(settings[k].matchCase), whole words \(settings[k].wholeWords): \(reader.debugSearchCount))")
                    snapshot(reader, "search-\(k + 1)")
                    if k == settings.count - 1 { report("after the four searches") }
                    after(1) { run(k + 1) }
                }
                after(0.5) { wait() }
            }
            after(15) { report("before searching"); run(0) }
            return
        }

        if mode == "previews" {
            // LUMA_PREVIEW_LINKS="2:67;2:I": the preview of each link (page:written as) in turn, a
            // snapshot of each (ADR 0006: where previews open).
            let wanted = (ProcessInfo.processInfo.environment["LUMA_PREVIEW_LINKS"] ?? "").split(separator: ";").compactMap { item -> (Int, String)? in
                let parts = item.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let page = Int(parts[0]) else { return nil }
                return (page, String(parts[1]))
            }
            // LUMA_PREVIEW_SWEEP=n: instead, n previews in turn, of the first link in view on page after
            // page through the document, with readings before, at the end and 15 s later.
            if let sweep = ProcessInfo.processInfo.environment["LUMA_PREVIEW_SWEEP"].flatMap(Int.init) {
                func step(_ k: Int) {
                    guard k < sweep else {
                        reader.debugDismissOverlays()
                        report("after \(sweep) previews")
                        after(15) { report("15 s later"); exit(0) }
                        return
                    }
                    reader.debugDismissOverlays()
                    reader.goToPage(k % max(1, reader.currentPageCount))
                    after(0.3) {
                        _ = reader.debugHoverFirstVisibleLink()
                        after(1.2) { step(k + 1) }
                    }
                }
                after(8) { _ = reader.debugHoverFirstVisibleLink(); reader.debugDismissOverlays() }
                after(20) { report("before the previews"); step(0) }
                return
            }
            func next(_ k: Int) {
                guard k < wanted.count else { exit(0) }
                reader.debugDismissOverlays()
                let shown = reader.debugHoverLink(onPage: wanted[k].0, written: wanted[k].1)
                print("  (link \"\(wanted[k].1)\" on page \(wanted[k].0): \(shown ? "preview shown" : "not found"))")
                after(2) {
                    snapshot(reader, "preview-\(k + 1)")
                    next(k + 1)
                }
            }
            after(8) { _ = reader.debugHoverFirstVisibleLink(); reader.debugDismissOverlays() }
            after(15) { next(0) }
            return
        }

        if mode == "refresh" {
            // ADR 0006, the experiment for 丙: one document paged through from first page to last and
            // searched, left on its third page; a reading; then the tab in front read afresh (or, with
            // LUMA_REFRESH_CONTROL, left alone), readings 15 and 30 s later. LUMA_REFRESH_SIDEBAR=thumbnails
            // or outline: with the sidebar open, snapshots before and after.
            switch ProcessInfo.processInfo.environment["LUMA_REFRESH_SIDEBAR"] {
            case "thumbnails": reader.showSidebar(.thumbnails)
            case "outline": reader.showSidebar(.outline)
            default: break
            }
            var page = 0
            Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { timer in
                if page < reader.currentPageCount {
                    reader.goToPage(page)
                    page += 1
                    return
                }
                timer.invalidate()
                reader.debugSearch(for: ProcessInfo.processInfo.environment["LUMA_REFRESH_SEARCH"] ?? "the")
                after(10) {
                    // LUMA_REFRESH_KEEP_SEARCH: the search bar left open, when reading afresh must not happen.
                    if ProcessInfo.processInfo.environment["LUMA_REFRESH_KEEP_SEARCH"] == nil { reader.debugCloseSearch() }
                    reader.goToPage(min(2, reader.currentPageCount - 1))
                    after(15) {
                        snapshot(reader, "refresh-before")
                        report("paged through and searched, 15 s later")
                        let before = reader.debugCurrentPlace
                        if ProcessInfo.processInfo.environment["LUMA_REFRESH_AUTO"] != nil {
                            // Left to read afresh by itself once idle long enough (LUMA_FRESHEN_AFTER).
                            // LUMA_REFRESH_MOVE: the file renamed meanwhile, when it must not be read afresh;
                            // put back at the end.
                            if ProcessInfo.processInfo.environment["LUMA_REFRESH_MOVE"] != nil, let url = reader.sessions.first?.url {
                                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("aside"))
                                after(29) { try? FileManager.default.moveItem(at: url.appendingPathExtension("aside"), to: url) }
                            }
                            print("  (left to read afresh by itself)")
                        } else if ProcessInfo.processInfo.environment["LUMA_REFRESH_CONTROL"] == nil {
                            let (done, seconds) = reader.debugRefreshFront()
                            print("  (read afresh: \(done), \(String(format: "%.2f", seconds)) s; place before \(before.map { "page \($0.page + 1), \(String(format: "%.3f", $0.y))" } ?? "-"), after \(reader.debugCurrentPlace.map { "page \($0.page + 1), \(String(format: "%.3f", $0.y))" } ?? "-"))")
                        } else {
                            print("  (control: left alone)")
                        }
                        after(15) {
                            snapshot(reader, "refresh-after")
                            report("15 s later")
                            after(15) {
                                snapshot(reader, "refresh-later")
                                report("30 s later")
                                print("  (read afresh by itself: \(reader.debugFreshenings) times; place \(reader.debugCurrentPlace.map { "page \($0.page + 1), \(String(format: "%.3f", $0.y))" } ?? "-"); save checks made: \(reader.debugChecksMade))")
                                exit(0)
                            }
                        }
                    }
                }
            }
            return
        }

        if mode == "figures" {
            // One document that links its own citations: readings before anything, with a preview of
            // a figure from three places in turn, and after, while and once its own reading document
            // is let go (ADR 0006).
            let start = ProcessInfo.processInfo.environment["LUMA_BENCH_PAGE"].flatMap { Int($0) }.map { $0 - 1 }
            reader.goToPage(min(max(0, start ?? reader.currentPageCount / 3), reader.currentPageCount - 1))
            after(3) { _ = reader.debugHoverFirstVisibleLink(figure: true); reader.debugDismissOverlays() }
            func previewFigure(_ round: Int) {
                guard round < 3 else {
                    after(5) {
                        report("5 s after the last preview")
                        after(12) {
                            print("  (figures' own document still held: \(reader.debugFigureReadingHeld))")
                            report("17 s after the last preview")
                            exit(0)
                        }
                    }
                    return
                }
                var tries = 0
                func attempt() {
                    if reader.debugHoverFirstVisibleLink(figure: true) {
                        after(3) {
                            report("figure preview \(round + 1) open")
                            reader.debugDismissOverlays()
                            reader.debugNudge(by: 700)
                            after(2) { previewFigure(round + 1) }
                        }
                    } else if tries < 8 {
                        tries += 1
                        reader.debugNudge(by: 250)
                        after(1) { attempt() }
                    } else {
                        print("  (no reference to a figure found in view)")
                        previewFigure(3)
                    }
                }
                attempt()
            }
            after(20) {
                report("before anything")
                previewFigure(0)
            }
            return
        }

        if mode == "pin" {
            // One document: readings before anything, with a preview, with it pinned, after scrolling
            // with it pinned, with a second preview pinned in its place, and after unpinning.
            let start = ProcessInfo.processInfo.environment["LUMA_BENCH_PAGE"].flatMap { Int($0) }.map { $0 - 1 }
            reader.goToPage(min(max(0, start ?? reader.currentPageCount / 2), reader.currentPageCount - 1))
            // Links worked out from the text are ready a moment after links are first asked for: tried
            // again each second, a few times, scrolling a little further each time.
            func hoverSoon(_ tries: Int, then work: @escaping (Bool) -> Void) {
                if reader.debugHoverFirstVisibleLink() { return work(true) }
                guard tries > 0 else { return work(false) }
                reader.debugDismissOverlays()
                reader.debugNudge(by: 120)
                after(1) { hoverSoon(tries - 1, then: work) }
            }
            // Links are asked for once first, so that working them out is not counted against the preview.
            after(3) { _ = reader.debugHoverFirstVisibleLink(); reader.debugDismissOverlays() }
            after(20) {
                report("before anything")
                hoverSoon(8) { shown in
                    print("  (a link preview \(shown ? "is showing" : "could not be shown"))")
                    after(5) {
                        report("preview open")
                        reader.debugPinPreview()
                        after(5) {
                            snapshot(reader, "pin-pinned")
                            report("one preview pinned")
                            // LUMA_PIN_ZOOM: also measures it zoomed in as far as it goes, and moved about.
                            if ProcessInfo.processInfo.environment["LUMA_PIN_ZOOM"] != nil {
                                let scale = reader.debugZoomPinned(by: 1000)
                                print("  (pinned preview zoomed to scale \(String(format: "%.2f", scale)))")
                                after(5) {
                                    snapshot(reader, "pin-zoomed")
                                    report("pinned preview zoomed in all the way, 5 s later")
                                    _ = reader.debugZoomPinned(by: 0.001)
                                    after(5) {
                                        report("zoomed out to the whole page, 5 s later")
                                        exit(0)
                                    }
                                }
                                return
                            }
                            // LUMA_PIN_LARGEST: also measures it made as large as it goes, then put back.
                            if ProcessInfo.processInfo.environment["LUMA_PIN_LARGEST"] != nil {
                                let before = reader.debugPinnedSize
                                reader.debugMakePinnedLargest()
                                print("  (pinned preview made \(Int(reader.debugPinnedSize.width))×\(Int(reader.debugPinnedSize.height)) from \(Int(before.width))×\(Int(before.height)))")
                                after(5) {
                                    snapshot(reader, "pin-largest")
                                    report("pinned preview made as large as it goes, 5 s later")
                                    // LUMA_PIN_MOVE: then the window moved to the main screen.
                                    guard ProcessInfo.processInfo.environment["LUMA_PIN_MOVE"] != nil, let main = NSScreen.screens.first else { exit(0) }
                                    let visible = main.visibleFrame
                                    reader.window.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
                                    after(5) {
                                        print("  (window moved to the main screen, scale \(reader.window.backingScaleFactor): pinned preview \(Int(reader.debugPinnedSize.width))×\(Int(reader.debugPinnedSize.height)))")
                                        report("window moved to the main screen, 5 s later")
                                        exit(0)
                                    }
                                }
                                return
                            }
                            reader.debugNudge(by: 300)
                            after(3) {
                                print("  (after scrolling the page, pinned: \(reader.debugIsPinned))")
                                hoverSoon(8) { shown in print("  (a second preview \(shown ? "is showing" : "could not be shown"))") }
                                after(12) {
                                    reader.debugPinPreview()
                                    after(5) {
                                        snapshot(reader, "pin-second")
                                        report("second preview pinned, the first closed")
                                        reader.debugUnpinPreview()
                                        after(5) {
                                            report("unpinned, 5 s later")
                                            // LUMA_PIN_SAVE: pin again, turn a page and save: saving page edits reads the
                                            // file again, and the pinned preview over the old reading must go.
                                            guard ProcessInfo.processInfo.environment["LUMA_PIN_SAVE"] != nil else { exit(0) }
                                            hoverSoon(4) { _ in
                                                reader.debugPinPreview()
                                                print("  (pinned before saving: \(reader.debugIsPinned))")
                                                reader.rotatePageRight(nil)
                                                reader.saveDocument(nil)
                                                after(4) { print("  (pinned after saving page edits: \(reader.debugIsPinned))"); exit(0) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return
        }

        if mode == "overlays" {
            // Start from the middle of the document, where a paper has links and figures in view.
            let start = ProcessInfo.processInfo.environment["LUMA_BENCH_PAGE"].flatMap { Int($0) }.map { $0 - 1 }
            reader.goToPage(min(max(0, start ?? reader.currentPageCount / 2), reader.currentPageCount - 1))
            let text = ProcessInfo.processInfo.environment["LUMA_HOVER_TEXT"]
            func hover() -> Bool { text.map { reader.debugHoverText($0) && reader.debugOverlays.contains("preview=true") } ?? reader.debugHoverFirstVisibleLink() }
            after(15) {
                report("before anything")
                // Links worked out from the text are ready a moment after links are first asked for.
                var shown = hover()
                if !shown { reader.debugDismissOverlays() }
                after(shown ? 0 : 2) {
                    if !shown { shown = hover() }
                    print("  (a link preview \(shown ? "is showing" : "could not be shown: no link in view"))")
                }
                after(shown ? 3 : 5) {
                    snapshot(reader, "overlays-preview")
                    report("preview open")
                    reader.debugDismissOverlays()
                    after(5) {
                        report("preview closed, 5 s later")
                        // Sweep the lens across the viewport the way a hand would.
                        var step = 0
                        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { timer in
                            if step >= 100 {
                                timer.invalidate()
                                report("magnifier on, lens just stopped moving")
                                after(5) {
                                    report("magnifier on, lens still for 5 s")
                                    reader.debugDismissOverlays()
                                    after(5) { report("magnifier off, 5 s later"); exit(0) }
                                }
                                return
                            }
                            let t = CGFloat(step) / 100
                            reader.debugMagnify(atViewportFraction: CGPoint(x: 0.1 + 0.8 * t, y: 0.2 + 0.6 * abs(sin(t * 6))))
                            step += 1
                        }
                    }
                }
            }
            return
        }

        if mode == "tabs" {
            var index = 0
            Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { timer in
                if index >= reader.sessions.count {
                    timer.invalidate()
                    after(15) { report("settled"); exit(0) }
                    return
                }
                reader.select(index)
                index += 1
            }
            return
        }

        if mode == "sleep" {
            // Several documents: each paged through from first page to last (so that the system engine
            // has met every page), the first left on its third page; a reading; then every background
            // tab put to sleep, a reading; then the first woken, a reading.
            var index = 0
            var page = 0
            Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { timer in
                if index < reader.sessions.count && page > 0 {
                    // Paging through the tab in front.
                    if page < reader.currentPageCount {
                        reader.goToPage(page)
                        page += 1
                        return
                    }
                    if index == 0 { reader.goToPage(min(2, reader.currentPageCount - 1)) }
                    index += 1
                    page = 0
                    return
                }
                if index >= reader.sessions.count {
                    timer.invalidate()
                    after(15) {
                        report("all awake, 15 s after showing each")
                        let before = reader.sessions.first?.position
                        // LUMA_SLEEP_CONTROL: the same steps and waits, with no tab put to sleep, to tell what
                        // sleeping saves from what the system lets go of by itself meanwhile.
                        if ProcessInfo.processInfo.environment["LUMA_SLEEP_CONTROL"] == nil { reader.debugPutTabsToSleep() }
                        print("  (first tab's place before sleeping: \(before.map { "page \($0.page + 1), \(String(format: "%.3f", $0.y)) down" } ?? "-"))")
                        print("  (sleeping tabs: \(reader.debugSleepingTabs) of \(reader.sessions.count))")
                        after(15) {
                            report("background tabs asleep, 15 s later")
                            // LUMA_SLEEP_MISSING: the first tab's file is moved away before it is chosen, then put back.
                            if ProcessInfo.processInfo.environment["LUMA_SLEEP_MISSING"] != nil, let url = reader.sessions.first?.url {
                                let aside = url.appendingPathExtension("aside")
                                try? FileManager.default.moveItem(at: url, to: aside)
                                reader.select(0)
                                print("  (file moved away: tabs \(reader.sessions.count), first still asleep: \(reader.sessions.first?.isAsleep ?? false))")
                                try? FileManager.default.moveItem(at: aside, to: url)
                                reader.select(1)
                            }
                            reader.select(0)
                            let place = reader.debugCurrentPlace
                            print("  (woken: first tab at \(place.map { "page \($0.page + 1), \(String(format: "%.3f", $0.y)) down" } ?? "-"), sleeping tabs: \(reader.debugSleepingTabs))")
                            after(15) { report("first tab woken, 15 s later"); exit(0) }
                        }
                    }
                    return
                }
                reader.select(index)
                page = 1
            }
            return
        }

        if mode == "paging" {
            let count = reader.currentPageCount
            let order = Array(0..<count) + Array((0..<count).reversed())
            after(15) {
                let viewport = reader.scrollView.contentView.bounds.size
                print("  viewport now \(Int(viewport.width))x\(Int(viewport.height))pt")
                report("settled 15 s")
                var step = 0
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                    if step >= order.count {
                        timer.invalidate()
                        after(15) { report("paged through, 15 s later") }
                        after(60) { report("paged through, 60 s later"); exit(0) }
                        return
                    }
                    reader.goToPage(order[step])
                    step += 1
                }
            }
            return
        }

        after(15) {
            // Said again here because a window can be resized behind the benchmark's back.
            let viewport = reader.scrollView.contentView.bounds.size
            print("  viewport now \(Int(viewport.width))x\(Int(viewport.height))pt")
            report("settled 15 s")
        }
        after(60) {
            report("settled 60 s")
            sweep(reader.scrollView) {
                // Two readings, to see whether what scrolling leaves behind drains away. So far it does not.
                after(15) { report("scrolled, 15 s later") }
                after(60) { report("scrolled, 60 s later"); exit(0) }
            }
        }
    }

    /// LUMA_BENCH=tour with LUMA_SNAPSHOTS=<folder>: walks through the main actions and saves a
    /// picture of the window after each, so a change can be checked by eye without touching the mouse.
    private static func tour(_ reader: ReaderWindowController) {
        let folder = ProcessInfo.processInfo.environment["LUMA_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        func snapshot(_ name: String) {
            print("  \(name): \(reader.debugSummary) \(reader.debugOverlays) \(reader.debugSearch)")
            fflush(stdout)
            guard let folder, let frame = reader.window.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let small = NSImage(size: NSSize(width: 760, height: 760 * frame.bounds.height / frame.bounds.width))
            small.lockFocus()
            rep.draw(in: NSRect(origin: .zero, size: small.size))
            small.unlockFocus()
            if let tiff = small.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }
        let steps: [(String, () -> Void)] = [
            ("1-opened", {}),
            ("2-first-tab-zoomed-in", { reader.select(0); reader.zoomIn(nil); reader.zoomIn(nil) }),
            ("3-fit-width-scrolled", {
                reader.zoomToFitWidth(nil)
                let clip = reader.scrollView.contentView
                clip.scroll(to: NSPoint(x: 0, y: ((reader.scrollView.documentView?.frame.height ?? 0) - clip.bounds.height) / 2))
                reader.scrollView.reflectScrolledClipView(clip)
            }),
            ("3a-link-preview", { reader.debugHoverFirstVisibleLink() }),
            ("3b-link-followed", { reader.debugDismissOverlays(); _ = reader.debugFollowFirstVisibleLink() }),
            ("3c-gone-back", { reader.goBack(nil) }),
            ("3d-magnifier", { reader.debugMagnify(atViewportFraction: CGPoint(x: 0.3, y: 0.45)) }),
            ("3e-magnifier-left-by-right-click", { reader.debugRightClickOnPage() }),
            ("3f-right-click-with-magnifier-off-does-nothing", { reader.debugRightClickOnPage() }),
            ("3g-sidebar-thumbnails", { reader.showSidebar(.thumbnails) }),
            ("3h-sidebar-outline", { reader.showSidebar(.outline) }),
            ("3i-search", { reader.debugSearch(for: "surface") }),
            ("3j-search-next-twice", { reader.findNext(nil); reader.findNext(nil) }),
            ("3k-search-and-sidebar-closed", { reader.debugCloseSearch(); reader.debugHideSidebar() }),
            ("4-switched-away-and-back", { reader.select(1); reader.select(0) }),
            ("5-all-but-one-closed", { while reader.sessions.count > 1 { reader.close(reader.sessions.count - 1) } }),
            ("6-empty", { reader.close(0) }),
        ]
        // One step at a time: act, give the window a moment to paint, take the picture, move on.
        // Steps on fixed timers would overtake each other whenever a picture took long to take.
        // LUMA_MARKS_STEPS=n stops after the first n steps, to see what each one costs.
        let stepCount = min(steps.count, Int(ProcessInfo.processInfo.environment["LUMA_MARKS_STEPS"] ?? "") ?? steps.count)
        func run(_ index: Int) {
            guard index < stepCount else { exit(0) }
            steps[index].1()
            after(0.7) {
                snapshot(steps[index].0)
                after(0.3) { run(index + 1) }
            }
        }
        after(1.5) { run(0) }
    }

    private static func snapshot(_ reader: ReaderWindowController, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["LUMA_SNAPSHOTS"].map({ URL(fileURLWithPath: $0) }),
              let frame = reader.window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: folder.appendingPathComponent("\(name).png")) }
    }

    /// LUMA_BENCH=marks: the marking and saving walk-through, with memory readings around it.
    private static func marks(_ reader: ReaderWindowController) {
        reader.goToPage(min(1, reader.currentPageCount - 1))
        var lines: [CGRect] = []
        func line(_ i: Int) -> CGRect { lines[min(i, lines.count - 1)] }
        func point(onLine i: Int) -> NSPoint { NSPoint(x: line(i).minX + line(i).width * 0.3, y: line(i).midY) }
        let steps: [(String, () -> Void)] = [
            ("m0-lines-found", {
                lines = reader.debugVisibleLines()
                print("  (\(lines.count) lines of text in view)")
            }),
            ("m1-selected", { reader.debugDrag(across: line(14)) }),
            ("m2-highlight-yellow", { reader.debugClickInMarkupPanel("Highlight") }),
            ("m3-second-selected", { reader.debugDrag(across: line(5)) }),
            ("m4-underline-red", { reader.debugClickInMarkupPanel("Red"); reader.debugClickInMarkupPanel("Underline") }),
            ("m5-undone", {
                print("  (menu would read \"\(reader.window.undoManager?.undoMenuItemTitle ?? "-")\")")
                reader.window.undoManager?.undo()
            }),
            ("m6-redone", { reader.window.undoManager?.redo() }),
            ("m7-third-selected-note-open", { reader.debugDrag(across: line(8)); reader.debugClickInMarkupPanel("Note"); reader.debugMarkupPanel(note: "测试附注 note") }),
            ("m8-note-done", { reader.debugPressDone() }),
            ("m8a-reading", { report("marks made, not saved") }),
            ("m8b-note-sign-clicked", { print("  (note sign \(reader.debugClickNoteSign() ? "clicked" : "not found"))") }),
            ("m9-saved", { reader.saveDocument(nil) }),
            ("m9a-reading", { report("saved once") }),
            ("m10-underline-clicked", { reader.debugClick(at: point(onLine: 5)) }),
            ("m11-underline-made-blue", { reader.debugClickInMarkupPanel("Blue") }),
            ("m12-highlight-clicked", { reader.debugClick(at: point(onLine: 14)) }),
            ("m13-highlight-deleted", { reader.debugClickInMarkupPanel("Delete") }),
            ("m14-saved-again", { reader.saveDocument(nil) }),
            ("m15-struck-through-green", { reader.debugDrag(across: line(20)); reader.debugClickInMarkupPanel("Green"); reader.debugClickInMarkupPanel("Strikethrough") }),
            ("m16-saved-third-time", { reader.saveDocument(nil) }),
        ]
        // LUMA_MARKS_STEPS=n stops after the first n steps, to see what each one costs.
        let stepCount = min(steps.count, Int(ProcessInfo.processInfo.environment["LUMA_MARKS_STEPS"] ?? "") ?? steps.count)
        func run(_ index: Int) {
            guard index < stepCount else {
                after(10) { report("after marking and saving, 10 s later") }
                after(30) { report("after marking and saving, 30 s later") }
                after(60) { report("after marking and saving, 60 s later"); readBack(); exit(0) }
                return
            }
            steps[index].1()
            after(1.0) {
                print("  \(steps[index].0): \(reader.debugMarks)")
                fflush(stdout)
                snapshot(reader, steps[index].0)
                after(0.3) { run(index + 1) }
            }
        }
        // Opens the saved file afresh, after the last reading so that it does not count.
        func readBack() {
                if let url = reader.sessions.first?.url, let reread = PDFDocument(url: url) {
                    var found: [String] = []
                    for i in 0..<reread.pageCount {
                        for a in reread.page(at: i)?.annotations ?? [] where MarkupEditor.isMark(a) {
                            let c = a.color.usingColorSpace(.sRGB) ?? a.color
                            found.append("p\(i + 1) \(a.type ?? "?") rgb(\(String(format: "%.2f,%.2f,%.2f", c.redComponent, c.greenComponent, c.blueComponent)))"
                                         + (a.contents.map { " note=\"\($0)\"" } ?? ""))
                        }
                    }
                    print("  file read afresh: [\(found.joined(separator: "; "))]")
                }
        }
        after(15) {
            report("before marking")
            run(0)
        }
    }

    /// LUMA_BENCH=pages: the page-editing walk-through, with memory readings around it.
    private static func pages(_ reader: ReaderWindowController) {
        // The document as edited before saving: once saved, the file is read again and this one should go.
        weak var edited: PDFDocument?
        weak var editedSession: DocumentSession?
        weak var insertedFrom: PDFDocument?
        let insert = ProcessInfo.processInfo.environment["LUMA_INSERT"].map { URL(fileURLWithPath: $0) }
        let actions = { reader.debugThumbnailActions }
        let steps: [(String, () -> Void)] = [
            ("p0-thumbnails", { reader.showSidebar(.thumbnails) }),
            ("p0b-toolbar-turns-the-page-in-view", {
                reader.goToPage(1)
                reader.rotatePageRight(nil)
                let after = reader.debugPages
                reader.rotatePageLeft(nil)
                print("  (toolbar turn: \(after.split(separator: "|")[1].trimmingCharacters(in: .whitespaces)); and back)")
            }),
            ("p1-first-turned-right", { actions().turn(0, true) }),
            ("p2-second-taken-out", {
                // Reading page 6: taking out page 2 must leave page 6 (now the 5th) in view.
                reader.goToPage(5)
                let before = reader.debugPageAtTop
                actions().takeOut(1)
                print("  (page at top: \(before + 1) before, \(reader.debugPageAtTop + 1) after; expected \(before))")
            }),
            ("p3a-first-picked-up-over-third", { reader.debugPickUpThumbnail(0, overGap: 3) }),
            ("p3-first-dragged-below-third", { reader.debugLetGoOfThumbnail() }),
            ("p4-inserted-after-first", { if let insert { actions().insert([insert], 1) } else { print("  (no LUMA_INSERT)") } }),
            ("p5-undone", {
                print("  (menu would read \"\(reader.window.undoManager?.undoMenuItemTitle ?? "-")\")")
                reader.window.undoManager?.undo()
            }),
            ("p6-redone", { reader.window.undoManager?.redo() }),
            ("p7-last-turned-left", { actions().turn(reader.currentPageCount - 1, false) }),
            ("p8-reading", { report("pages edited, not saved") }),
            ("p9-saved-as", {
                // LUMA_SAVE_AS=<path>: 另存为 with everything unsaved. The tab then shows the new file and
                // has nothing left to save, so the save below writes nothing; the original stays as it was.
                guard let path = ProcessInfo.processInfo.environment["LUMA_SAVE_AS"] else { return }
                edited = reader.sessions.first?.document
                editedSession = reader.sessions.first
                insertedFrom = reader.sessions.first?.pages.sources.first?.document
                reader.debugSaveAs(to: URL(fileURLWithPath: path))
                print("  (tab now shows \(reader.sessions.first?.url.lastPathComponent ?? "-"), unsaved: \(reader.sessions.first?.hasUnsavedChanges ?? true))")
            }),
            ("p10-saved", {
                if ProcessInfo.processInfo.environment["LUMA_SAVE_AS"] == nil {
                    edited = reader.sessions.first?.document
                    editedSession = reader.sessions.first
                    insertedFrom = reader.sessions.first?.pages.sources.first?.document
                }
                reader.saveDocument(nil)
            }),
        ]
        // LUMA_PAGES_STEPS=n stops after the first n steps, to see what each one costs.
        let stepCount = min(steps.count, Int(ProcessInfo.processInfo.environment["LUMA_PAGES_STEPS"] ?? "") ?? steps.count)
        func run(_ index: Int) {
            guard index < stepCount else {
                after(10) { report("after editing and saving, 10 s later") }
                after(30) { report("after editing and saving, 30 s later") }
                after(60) { report("after editing and saving, 60 s later") }
                after(120) {
                    report("after editing and saving, 120 s later")
                    print("  the document as edited before saving is \(edited == nil ? "gone" : "STILL HELD"), its tab's session \(editedSession == nil ? "gone" : "STILL HELD"), the document inserted from \(insertedFrom == nil ? "gone" : "STILL HELD")")
                    malloc_zone_pressure_relief(nil, 0)
                    report("after asking the system to take back free memory")
                    print("  shown afresh: \(reader.debugPages)")
                    if let url = reader.sessions.first?.url, let reread = PDFDocument(url: url) {
                        let pages = (0..<reread.pageCount).map { i -> String in
                            let words = (reread.page(at: i)?.string ?? "").split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
                            return "\(i + 1):\(words.prefix(24))@\(reread.page(at: i)?.rotation ?? -1)"
                        }
                        print("  file read afresh: \(pages.joined(separator: " | "))")
                    }
                    exit(0)
                }
                return
            }
            steps[index].1()
            // Each step ends as a hand's would, with the event it came in finishing: that is what
            // closes an undo step.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: reader.window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: false)
            }
            after(1.0) {
                print("  \(steps[index].0): \(reader.debugPages)")
                fflush(stdout)
                snapshot(reader, steps[index].0)
                after(0.3) { run(index + 1) }
            }
        }
        after(15) {
            report("before editing pages")
            print("  start: \(reader.debugPages)")
            run(0)
        }
    }

    /// LUMA_BENCH=everything: the whole of stage one used in a row, as a reader might in a sitting.
    private static func everything(_ reader: ReaderWindowController) {
        let count = reader.currentPageCount
        let order = Array(0..<count) + Array((0..<count).reversed())
        var steps: [(Double, () -> Void)] = []
        var clock = 15.0
        func at(_ delay: Double, _ work: @escaping () -> Void) { clock += delay; steps.append((clock, work)) }
        steps.append((15, { report("settled 15 s") }))
        for (k, page) in order.enumerated() { steps.append((15 + Double(k + 1) * 0.5, { reader.goToPage(page) })) }
        clock = 15 + Double(order.count) * 0.5
        at(15) { report("paged through, 15 s later") }
        at(0.1) { reader.showSidebar(.thumbnails) }
        at(8) { report("sidebar showing thumbnails") }
        at(0.1) { reader.showSidebar(.outline) }
        at(4) { reader.debugHideSidebar(); reader.debugSearch(for: "the") }
        at(12) { report("search results on show") }
        at(0.1) { reader.debugCloseSearch(); reader.goToPage(min(1, count - 1)) }
        at(1.5) {
            let lines = reader.debugVisibleLines()
            reader.debugDrag(across: lines[min(14, lines.count - 1)])
            reader.debugClickInMarkupPanel("Highlight")
        }
        at(1.5) {
            let lines = reader.debugVisibleLines()
            reader.debugDrag(across: lines[min(8, lines.count - 1)])
            reader.debugClickInMarkupPanel("Note")
            reader.debugMarkupPanel(note: "一条附注")
            reader.debugPressDone()
        }
        at(1.5) { reader.saveDocument(nil) }
        at(2) {
            let lines = reader.debugVisibleLines()
            reader.debugDrag(from: lines[min(16, lines.count - 3)], to: lines[min(18, lines.count - 1)])
            _ = reader.debugCopiedText(cleaned: true)
            report("marked, saved and copied")
        }
        at(15) { report("everything done, 15 s later") }
        at(45) { report("everything done, 60 s later"); print("  (\(reader.debugMarks))"); exit(0) }
        for (time, work) in steps { after(time, work) }
    }

    /// LUMA_BENCH=closing with two or more copies and LUMA_ANSWERS: marks a line in every tab, then
    /// asks to close everything, the questions answered from LUMA_ANSWERS, and reads the files back.
    private static func closing(_ reader: ReaderWindowController) {
        reader.goToPage(min(1, reader.currentPageCount - 1))
        var tab = 0
        func markNext() {
            guard tab < reader.sessions.count else {
                after(1) {
                    print("  closing everything: may close = \(reader.confirmClosingAll())")
                    for session in reader.sessions {
                        let marks = PDFDocument(url: session.url).map { doc in
                            (0..<doc.pageCount).flatMap { doc.page(at: $0)?.annotations.filter(MarkupEditor.isMark) ?? [] }.count
                        } ?? -1
                        print("  \(session.url.lastPathComponent): marks in the file = \(marks), unsaved = \(session.hasUnsavedChanges)")
                    }
                    exit(0)
                }
                return
            }
            reader.select(tab)
            after(0.8) {
                let lines = reader.debugVisibleLines()
                reader.debugDrag(across: lines[min(17, lines.count - 1)])
                reader.debugClickInMarkupPanel("Highlight")
                tab += 1
                after(0.5) { markNext() }
            }
        }
        after(3) { markNext() }
    }

    /// LUMA_BENCH=extras: copying, going to a typed page, saving after the file was changed behind
    /// the app's back, and reloading it.
    private static func extras(_ reader: ReaderWindowController) {
        // LUMA_EXTRAS_RELOADS=n: only reload the document n times, with readings before and after,
        // to see whether earlier copies of it are let go.
        if let count = Int(ProcessInfo.processInfo.environment["LUMA_EXTRAS_RELOADS"] ?? "") {
            after(10) {
                report("before reloading")
                for k in 0..<count { after(Double(k) * 1.5) { reader.reloadDocument(nil) } }
                after(Double(count) * 1.5 + 10) { report("reloaded \(count) times, 10 s later"); exit(0) }
            }
            return
        }
        reader.goToPage(min(1, reader.currentPageCount - 1))
        var lines: [CGRect] = []
        let fm = FileManager.default
        // An untouched copy of the document, to stand in for "the new version another program wrote".
        let original = ProcessInfo.processInfo.environment["LUMA_EXTRAS_ORIGINAL"].map { URL(fileURLWithPath: $0) }
        var file: URL { reader.sessions.first?.url ?? URL(fileURLWithPath: "/") }
        let steps: [(String, () -> Void)] = [
            ("x1-three-lines-selected", {
                lines = reader.debugVisibleLines()
                reader.debugDrag(from: lines[min(14, lines.count - 3)], to: lines[min(16, lines.count - 1)])
                print("  original: \(reader.debugCopiedText(cleaned: false).debugDescription)")
                print("  cleaned:  \(reader.debugCopiedText(cleaned: true).debugDescription)")
            }),
            ("x1b-dictionary", {
                print("  (dictionary says electrochemical is a word: \(reader.debugAskDictionary()))")
                after(0.5) { report("after the first copy that asks the dictionary") }
            }),
            ("x2-typed-page-5", { reader.debugTypePage("5") }),
            ("x3-typed-nonsense", { reader.debugTypePage("abc") }),
            ("x4-back", { reader.goBack(nil) }),
            ("x5-marked", { reader.debugDrag(across: lines[min(17, lines.count - 1)]); reader.debugClickInMarkupPanel("Highlight") }),
            ("x6-saved-no-question-expected", { reader.saveDocument(nil) }),
            ("x7-second-mark-unsaved", {
                reader.debugDrag(across: lines[min(12, lines.count - 1)])
                reader.debugClickInMarkupPanel("Green")
                reader.debugClickInMarkupPanel("Highlight")
            }),
            ("x7b-saved-mark-made-red", {
                let line = lines[min(17, lines.count - 1)]
                reader.debugClick(at: NSPoint(x: line.minX + line.width * 0.3, y: line.midY))
                reader.debugClickInMarkupPanel("Red")
            }),
            ("x8-changed-elsewhere", { try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }),
            ("x9-save-refused", { reader.saveDocument(nil) }),
            ("x10-reloaded-red-and-green-carried", { reader.reloadDocument(nil) }),
            ("x11-replaced-by-another-version-reload-kept", {
                // Another version of the file (here, the untouched original): the red mark has no place in it.
                try? fm.removeItem(at: file)
                if let original { try? fm.copyItem(at: original, to: file) }
                reader.reloadDocument(nil)
            }),
            ("x12-reloaded-anyway", { reader.reloadDocument(nil) }),
        ]
        func run(_ index: Int) {
            guard index < steps.count else { exit(0) }
            steps[index].1()
            after(1.2) {
                print("  \(steps[index].0): \(reader.debugSummary.split(separator: " ").filter { $0.hasPrefix("page=") || $0.hasPrefix("\"") || $0.contains("/") }.joined(separator: " "))")
                print("      \(reader.debugMarks)")
                print("      \(reader.debugFile) sheet=\(reader.debugSheet)")
                fflush(stdout)
                after(0.3) { run(index + 1) }
            }
        }
        after(5) { report("before"); run(0) }
    }

    /// Scrolls through the whole document and back in 160 steps each way.
    private static func sweep(_ scroll: NSScrollView, then done: @escaping () -> Void) {
        let clip = scroll.contentView
        let start = clip.bounds.origin
        let highest = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        var positions = (0...160).map { highest * CGFloat($0) / 160 }
        positions += positions.reversed()
        var index = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if index >= positions.count {
                timer.invalidate()
                clip.scroll(to: start)
                scroll.reflectScrolledClipView(clip)
                done()
                return
            }
            clip.scroll(to: NSPoint(x: start.x, y: positions[index]))
            scroll.reflectScrolledClipView(clip)
            index += 1
        }
    }
}
