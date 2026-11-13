import AppKit
import os
import ScopesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let lightroomBundleID = "com.adobe.LightroomClassicCC7"

    private let log = Logger(subsystem: "com.lrcscopes.helper", category: "app")
    private let options: LaunchOptions
    private var connection: PluginConnection?
    private let processor = FrameProcessor()
    private var panel: ScopesPanelController!

    private var connected = false
    private var protocolMismatch: Int?
    private var latestState: PluginState?
    private var lastMessageAt: Date?
    private var currentPhotoId: Int?
    private var hasFrame = false
    private var previewSize: (width: Int, height: Int)?
    /// Set when Lightroom could not render the current photo.
    private var previewError: (photoId: Int, reason: String?)?
    private var staleTraceCheck: DispatchWorkItem?
    private var terminating = false
    private var stalenessTimer: Timer?
    /// Keeps App Nap away: when the panel is hidden (outside Develop) macOS would
    /// otherwise throttle the connection handling while Lightroom keeps sending.
    private var activity: NSObjectProtocol?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Live scopes for Lightroom Classic")
        removeLegacySessionDirectory()

        panel = ScopesPanelController(settings: ScopeSettings.load(), closable: options.port == nil)
        panel.setMessage("Waiting for Lightroom Classic…")
        panel.onSettingsChanged = { [weak self] settings in
            self?.processor.submit(jpeg: nil, settings: settings)
        }
        panel.onUserClosed = { [weak self] in
            // Only a helper started by hand has a close button.
            guard let self, !self.terminating else { return }
            NSApp.terminate(nil)
        }

        processor.onOutput = { [weak self] output in
            guard let self else { return }
            self.panel.display(output)
            self.previewSize = output.previewSize
            self.updateStatusAndMessage()
            self.log.debug("Frame processed in \(output.processingTime * 1000, format: .fixed(precision: 1)) ms")
        }
        processor.onError = { [weak self] message in
            self?.panel.setMessage("Could not read the preview from Lightroom.\n\(message)")
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(activeAppChanged(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        if let port = options.port {
            let c = PluginConnection(port: port)
            c.onEvent = { [weak self] event in self?.handle(event) }
            c.start()
            connection = c
        } else {
            // Started by hand rather than by the plug-in: there is nothing to connect to.
            panel.setMessage("Open the scopes from Lightroom Classic:\nFile › Plug-in Extras › Show Scopes")
            panel.show(true)
        }

        // Staleness is a function of time, not of events.
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateStatusAndMessage()
            self?.updateVisibility()
        }
        updateVisibility()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        connection?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Connection events

    private func handle(_ event: PluginConnection.Event) {
        switch event {
        case .connected:
            connected = true
            lastMessageAt = Date()
        case .disconnected:
            connected = false
        case .gaveUp:
            log.info("Lost Lightroom; exiting")
            NSApp.terminate(nil)
            return
        case .message(let message):
            lastMessageAt = Date()
            handle(message)
        }
        updateStatusAndMessage()
        updateVisibility()
    }

    private func handle(_ message: PluginMessage) {
        switch message {
        case .hello(let version, let pluginVersion):
            log.info("Plug-in \(pluginVersion ?? "?", privacy: .public), protocol \(version)")
            protocolMismatch = version == WireProtocol.version ? nil : version
        case .state(let state):
            let previousPhoto = latestState?.photo?.id
            latestState = state
            if state.photo == nil {
                clearScopes()
            } else if state.photo?.id != previousPhoto, state.photo?.id != currentPhotoId {
                scheduleStaleTraceCheck()
            }
        case .frame(let frame):
            guard protocolMismatch == nil else { return }
            logFrame(frame)
            // A region is drawn on one particular photo; don't carry it to the next.
            if let previous = currentPhotoId, previous != frame.photoId {
                panel.resetRegion()
            }
            currentPhotoId = frame.photoId
            previewError = nil
            hasFrame = true
            processor.submit(jpeg: frame.jpeg, settings: panel.settings)
        case .previewError(let photoId, let reason):
            log.error("Lightroom could not render a preview: \(reason ?? "?", privacy: .public)")
            guard photoId == latestState?.photo?.id else { return }
            previewError = (photoId, reason)
            clearScopes()
        case .quit:
            log.info("Plug-in requested exit")
            NSApp.terminate(nil)
        }
    }

    private func clearScopes() {
        hasFrame = false
        previewSize = nil
        currentPhotoId = nil
        panel.clearTraces()
    }

    /// When another photo is selected, its frame normally arrives within a fraction of
    /// a second. If it doesn't, stop showing the previous photo's scopes rather than
    /// leave them up under the new photo's name.
    private func scheduleStaleTraceCheck() {
        staleTraceCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let photo = self.latestState?.photo, self.currentPhotoId != photo.id else { return }
            self.clearScopes()
            self.updateStatusAndMessage()
        }
        staleTraceCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func logFrame(_ frame: FrameMessage) {
        let transferMs = frame.sentAt.map { (Date().timeIntervalSinceReferenceDate - $0) * 1000 }
        log.debug("Frame \(frame.seq): \(frame.jpeg.count) bytes, render \(frame.renderMs ?? -1) ms, transfer \(transferMs ?? -1, format: .fixed(precision: 1)) ms")
    }

    private var isPluginResponsive: Bool {
        guard connected, let last = lastMessageAt else { return false }
        return Date().timeIntervalSince(last) <= WireProtocol.staleAfter
    }

    // MARK: - Presentation

    /// True while the scopes don't show the latest edit yet: the plug-in says it is
    /// waiting for Lightroom, or the selected photo's first frame hasn't arrived.
    private var isAwaitingUpdate: Bool {
        guard protocolMismatch == nil, isPluginResponsive, let state = latestState,
              let photo = state.photo else { return false }
        if let error = previewError, error.photoId == photo.id { return false }
        return state.updating == true || currentPhotoId != photo.id
    }

    private func updateStatusAndMessage() {
        guard options.port != nil else { return }
        panel.setUpdating(isAwaitingUpdate)
        if let v = protocolMismatch {
            panel.setStatus("")
            panel.setMessage("The scopes app and the Lightroom plug-in don't match (protocol \(v) vs \(WireProtocol.version)).\nReinstall the LRC Scopes plug-in.")
            return
        }
        guard connected, let state = latestState else {
            panel.setStatus("")
            panel.setMessage("Waiting for Lightroom Classic…")
            return
        }
        guard isPluginResponsive else {
            panel.setStatus("")
            panel.setMessage("Lightroom is not responding to the scopes plug-in.")
            return
        }
        guard let photo = state.photo else {
            panel.setStatus("")
            panel.setMessage("No photo selected.")
            return
        }
        let name = photo.name ?? ""
        if let error = previewError, error.photoId == photo.id {
            panel.setStatus(name)
            panel.setMessage("Lightroom could not render a preview of this photo" +
                             (error.reason.map { " (\($0))" } ?? "") + ".\nRetrying…")
            return
        }
        if currentPhotoId != photo.id {
            panel.setStatus("\(name) — updating…")
        } else if let size = previewSize {
            panel.setStatus("\(name) — \(size.width)×\(size.height) preview")
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
        if options.alwaysShow || options.port == nil { panel.show(true); return }
        guard isPluginResponsive, let state = latestState, state.enabled, state.isInDevelop else {
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

    /// Protocol 1 exchanged files in this folder. It only ever held this app's own
    /// frames and state, so it is safe to remove.
    private func removeLegacySessionDirectory() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.lrcscopes.session", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacy)
            log.info("Removed legacy session folder")
        } catch {
            log.error("Could not remove legacy session folder: \(String(describing: error), privacy: .public)")
        }
    }
}

struct LaunchOptions: Equatable {
    /// The plug-in's LrSocket port. nil when started by hand.
    var port: UInt16?
    /// Debug aid: keep the panel visible regardless of Lightroom state.
    var alwaysShow = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--port":
                if let value = it.next(), let port = UInt16(value), port > 0 { o.port = port }
            case "--always-show":
                o.alwaysShow = true
            default:
                break // Ignore unknown/system arguments such as -NSDocumentRevisionsDebugMode.
            }
        }
        return o
    }
}
