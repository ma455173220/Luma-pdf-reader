import AppKit

/// The few colours the app chooses for itself. Everything else follows the system.
enum Theme {
    /// The surface behind the pages: a quiet grey that sets the white pages apart without calling
    /// attention to itself. It darkens with the system's dark appearance; the pages do not.
    static let canvas = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.94, alpha: 1)
    }

    /// A hairline around each page, so its edge stays visible where page and surface are close in tone.
    static let pageEdge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0, alpha: 1) : NSColor(white: 0, alpha: 0.12)
    }

    /// Search matches on the page. The pages are always white, so these do not change with the appearance.
    static let searchMatch = NSColor(red: 1, green: 0.92, blue: 0.35, alpha: 1)
    static let currentSearchMatch = NSColor(red: 1, green: 0.62, blue: 0.1, alpha: 1)
    /// A pale box behind the link under the pointer, multiplied into the white page.
    static let linkHover = NSColor(red: 0.82, green: 0.89, blue: 1, alpha: 1)
}
