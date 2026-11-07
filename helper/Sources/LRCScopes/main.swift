import AppKit

// Single instance: if another helper is already running, defer to it.
let bundleID = Bundle.main.bundleIdentifier ?? "com.lrcscopes.helper"
let me = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != me }) {
    exit(0)
}

let app = NSApplication.shared
// Accessory: no Dock icon or menu bar; the panel floats over Lightroom.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(options: LaunchOptions.parse(CommandLine.arguments))
app.delegate = delegate
app.run()
