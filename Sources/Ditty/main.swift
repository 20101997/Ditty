import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar app: no Dock icon, like Ditto living in the Windows tray.
app.setActivationPolicy(.accessory)
app.run()
