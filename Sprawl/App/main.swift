import AppKit

// AppKit entry point. Because this file is named `main.swift`, this top-level
// code is the program's entry point (so we don't use @main / a storyboard).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
