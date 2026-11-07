import AppKit
import os
import ScopesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let lightroomBundleID = "com.adobe.LightroomClassicCC7"

    private let log = Logger(subsystem: "com.lrcscopes.helper", category: "app")
    private let options: LaunchOptions
    private var session: SessionClient!
    private let processor = FrameProcessor()
    private var panel: ScopesPanelController!

    private var latestState: PluginState?
    private var hasFrame = false
    private var currentFrame: PluginState.Frame?

    init(options: LaunchOptions) {
        self.options = options
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = ScopesPanelController(settings: ScopeSettings.load())
        panel.setMessage("Waiting for Lightroom Classic…")
        panel.onSettingsChanged = { [weak self] settings in
            self?.processor.submit(jpeg: nil, settings: settings)
        }
        panel.onUserClosed = { [weak self] in
            self?.log.info("Scopes window closed by user; exiting")
            NSApp.terminate(nil)
        }

        processor.onOutput = { [weak self] output in
            guard let self else { return }
            self.panel.display(output)
            self.log.debug("Frame processed in \(output.processingTime * 1000, format: .fixed(precision: 1)) ms")
        }
        processor.onError = { [weak self] message in
            self?.panel.setMessage("Could not read the preview from Lightroom.\n\(message)")
        }

        session = SessionClient(directory: options.sessionDirectory, version: version)
        session.onUpdate = { [weak self] update in self?.handle(update) }
        do {
            try session.start()
        } catch {
            log.fault("Cannot watch session directory: \(String(describing: error), privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = "LRC Scopes cannot access its session folder."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(activeAppChanged(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        if options.alwaysShow { panel.show(true) }
        updateVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - State handling

    private func handle(_ update: SessionClient.Update) {
        latestState = update.state

        if let state = update.state, state.quit == true {
            log.info("Plug-in requested exit")
            NSApp.terminate(nil)
            return
        }

        if let (jpeg, frame) = update.newFrame {
            currentFrame = frame
            hasFrame = true
            processor.submit(jpeg: jpeg, settings: panel.settings)
        }

        updateStatusAndMessage()
        updateVisibility()
    }

    private func updateStatusAndMessage() {
        guard let state = latestState else {
            panel.setStatus("")
            panel.setMessage("Waiting for Lightroom Classic…\nEnable the LRC Scopes plug-in in the Plug-in Manager.")
            return
        }
        if !state.isFresh() {
            panel.setStatus("")
            panel.setMessage("Lightroom is not responding to the scopes plug-in.")
            return
        }
        if state.photo == nil {
            panel.clearTraces()
            hasFrame = false
            panel.setStatus("")
            panel.setMessage("No photo selected.")
            return
        }
        let name = state.photo?.name ?? ""
        if let frame = currentFrame, let photo = state.photo, frame.photoId != photo.id {
            panel.setStatus("\(name) — updating…")
        } else if let frame = currentFrame, let w = frame.width, let h = frame.height {
            panel.setStatus("\(name) — \(w)×\(h) preview")
        } else {
            panel.setStatus(name)
        }
        if !hasFrame {
            panel.setMessage("Rendering preview…")
        }
    }

    /// The panel is shown only while it is useful: the plug-in is alive and enabled,
    /// Lightroom is in Develop, and Lightroom (or the panel itself) is frontmost.
    private func updateVisibility() {
        if options.alwaysShow { panel.show(true); return }
        guard let state = latestState, state.isFresh(), state.enabled, state.isInDevelop else {
            panel.show(false)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let lightroomFront = front?.bundleIdentifier == Self.lightroomBundleID
        let selfFront = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        panel.show(lightroomFront || selfFront)
    }

    @objc private func activeAppChanged(_ note: Notification) {
        updateVisibility()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Self.lightroomBundleID {
            log.info("Lightroom Classic quit; exiting")
            NSApp.terminate(nil)
        }
    }
}

struct LaunchOptions {
    var sessionDirectory: URL = SessionProtocol.defaultSessionDirectory
    /// Debug aid: keep the panel visible regardless of Lightroom state.
    var alwaysShow = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--session-dir":
                if let path = it.next(), !path.isEmpty {
                    o.sessionDirectory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                }
            case "--always-show":
                o.alwaysShow = true
            default:
                break // Ignore unknown/system arguments such as -NSDocumentRevisionsDebugMode.
            }
        }
        return o
    }
}
