//  main.swift — entry point (menu-bar utility, NSApplication).

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
