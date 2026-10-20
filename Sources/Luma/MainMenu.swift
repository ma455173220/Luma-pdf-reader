import AppKit

/// The menu bar, built in code. Every item's wording is in Chinese, as the interface is.
enum MainMenu {
    static func build(reader: ReaderWindowController, application: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func menu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            build(submenu)
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }

        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, hidden: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            if hidden {
                // An extra way to press the same command; it never shows in the menu.
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
            menu.addItem(item)
            return item
        }

        _ = menu("知白") { m in
            add(m, L("About 知白"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            add(m, L("Hide 知白"), #selector(NSApplication.hide(_:)), "h")
            add(m, L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, L("Show All"), #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, L("Quit 知白"), #selector(NSApplication.terminate(_:)), "q")
        }

        _ = menu(L("File")) { m in
            add(m, L("Open…"), #selector(AppDelegate.openDocument(_:)), "o", target: application)
            let recent = add(m, L("Open Recent"), nil)
            recent.submenu = NSMenu(title: L("Open Recent"))
            recent.submenu?.delegate = application
            m.addItem(.separator())
            add(m, L("Close Tab"), #selector(ReaderWindowController.closeCurrentTab(_:)), "w", target: reader)
            add(m, L("Save"), #selector(ReaderWindowController.saveDocument(_:)), "s", target: reader)
            add(m, L("Save As…"), #selector(ReaderWindowController.saveDocumentAs(_:)), "s", [.command, .shift], target: reader)
            add(m, L("Reload"), #selector(ReaderWindowController.reloadDocument(_:)), target: reader)
        }

        // Needed even before text can be selected in a page: without it ⌘V does nothing in the
        // password box. These go to whatever has the keyboard focus.
        _ = menu(L("Edit")) { m in
            add(m, L("Undo"), Selector(("undo:")), "z")
            add(m, L("Redo"), Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            add(m, L("Cut"), #selector(NSText.cut(_:)), "x")
            add(m, L("Copy"), #selector(NSText.copy(_:)), "c")
            add(m, L("Copy Original Text"), #selector(PageCanvasView.copyOriginalText(_:)), "c", [.command, .option])
            add(m, L("Paste"), #selector(NSText.paste(_:)), "v")
            add(m, L("Select All"), #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            add(m, L("Find…"), #selector(ReaderWindowController.showSearch(_:)), "f", target: reader)
            add(m, L("Find Next"), #selector(ReaderWindowController.findNext(_:)), "g", target: reader)
            add(m, L("Find Previous"), #selector(ReaderWindowController.findPrevious(_:)), "g", [.command, .shift], target: reader)
        }

        _ = menu(L("View")) { m in
            add(m, L("Sidebar"), #selector(ReaderWindowController.toggleSidebar(_:)), "s", [.command, .option], target: reader)
            m.addItem(.separator())
            add(m, L("Zoom In"), #selector(ReaderWindowController.zoomIn(_:)), "+", target: reader)
            add(m, L("Zoom In"), #selector(ReaderWindowController.zoomIn(_:)), "=", target: reader, hidden: true)
            add(m, L("Zoom Out"), #selector(ReaderWindowController.zoomOut(_:)), "-", target: reader)
            add(m, L("Fit Width"), #selector(ReaderWindowController.zoomToFitWidth(_:)), "0", target: reader)
            add(m, L("Magnifier"), #selector(ReaderWindowController.toggleMagnifier(_:)), target: reader)
            m.addItem(.separator())
            add(m, L("Rotate Right"), #selector(ReaderWindowController.rotatePageRight(_:)), "r", target: reader)
            add(m, L("Rotate Left"), #selector(ReaderWindowController.rotatePageLeft(_:)), "l", target: reader)
            m.addItem(.separator())
            add(m, L("Next Tab"), #selector(ReaderWindowController.selectNextTab(_:)), "]", [.command, .shift], target: reader)
            add(m, L("Previous Tab"), #selector(ReaderWindowController.selectPreviousTab(_:)), "[", [.command, .shift], target: reader)
            add(m, L("Next Tab"), #selector(ReaderWindowController.selectNextTab(_:)), "\t", [.control], target: reader, hidden: true)
            add(m, L("Previous Tab"), #selector(ReaderWindowController.selectPreviousTab(_:)), "\t", [.control, .shift], target: reader, hidden: true)
        }

        _ = menu(L("Go")) { m in
            add(m, L("Back"), #selector(ReaderWindowController.goBack(_:)), "[", target: reader)
            add(m, L("Forward"), #selector(ReaderWindowController.goForward(_:)), "]", target: reader)
            m.addItem(.separator())
            add(m, L("Go to Page…"), #selector(ReaderWindowController.typePageNumber(_:)), "g", [.command, .option], target: reader)
        }

        let windowMenu = menu(L("Window")) { m in
            add(m, L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, L("Zoom"), #selector(NSWindow.performZoom(_:)))
        }
        NSApp.windowsMenu = windowMenu
        return main
    }
}
