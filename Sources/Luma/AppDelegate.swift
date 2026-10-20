import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var reader: ReaderWindowController?
    /// Files the system asked to open before the window existed.
    private var waiting: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let reader = ReaderWindowController(remembersFrame: !Benchmark.isRequested)
        self.reader = reader
        NSApp.mainMenu = MainMenu.build(reader: reader, application: self)
        if Benchmark.isRequested {
            // A walk-through stays out of the way: no Dock icon, no taking the keyboard, its window
            // on the second display.
            NSApp.setActivationPolicy(.accessory)
            Benchmark.placeWindow(reader.window)
            reader.window.orderFrontRegardless()
        } else {
            reader.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Files named on the command line open too, which is how the benchmark starts the app.
        let named = CommandLine.arguments.dropFirst().filter { $0.lowercased().hasSuffix(".pdf") }.map { URL(fileURLWithPath: $0) }
        let toOpen = waiting + named
        waiting = []
        if !toOpen.isEmpty { reader.open(toOpen) }
        Benchmark.startIfRequested(reader)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let reader { reader.open(urls) } else { waiting += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting with unsaved marks asks about each document first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let reader else { return .terminateNow }
        // Not in the middle of a save or another question: quit again once it is done.
        guard NSApp.modalWindow == nil else { return .terminateCancel }
        return reader.confirmClosingAll() ? .terminateNow : .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Recent documents

    /// The 「打开最近使用」 menu, filled from the system's own list each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = NSDocumentController.shared.recentDocumentURLs
        let names = recent.map { FileManager.default.displayName(atPath: $0.path) }
        for (url, name) in zip(recent, names) {
            // Files of the same name are told apart by their folder.
            let title = names.filter { $0 == name }.count > 1 ? "\(name) — \(url.deletingLastPathComponent().lastPathComponent)" : name
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if recent.isEmpty {
            menu.addItem(NSMenuItem(title: L("No Recent Documents"), action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: L("Clear Menu"), action: #selector(clearRecent(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        reader?.open([url])
    }

    @objc private func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        reader?.open(panel.urls)
    }
}
