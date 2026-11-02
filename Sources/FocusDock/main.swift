import AppKit
import FocusDockKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon; lives in the menu bar + floating dock
app.run()
