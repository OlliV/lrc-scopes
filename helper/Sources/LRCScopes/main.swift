import AppKit

let options = LaunchOptions.parse(CommandLine.arguments)

// One helper at a time. The plug-in launches a fresh instance (`open -n`) with the
// port of its current socket; that newest instance wins, because an older one may be
// trying to reach a socket that no longer exists (e.g. after a plug-in reload).
let bundleID = Bundle.main.bundleIdentifier ?? "com.lrcscopes.helper"
let me = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != me }
if !others.isEmpty {
    if options.port == nil { exit(0) } // started by hand while one is running: defer to it
    others.forEach { $0.terminate() }
}

let app = NSApplication.shared
// Accessory: no Dock icon or menu bar; the panel floats over Lightroom.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
