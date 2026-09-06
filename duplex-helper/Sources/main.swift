import AppKit

// Explicit AppKit lifecycle: we create the window ourselves in the delegate,
// so it appears deterministically however the app is launched (Finder, `open`,
// direct exec, or the --snapshot harness).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
