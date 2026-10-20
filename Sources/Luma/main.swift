import AppKit

// Started as the helper that works out an outline: does that and exits, without a window.
OutlineProcess.runIfAsked()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
