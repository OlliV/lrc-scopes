import Foundation
import os
import ScopesCore

/// Watches the session directory for state/frame updates from the Lightroom plug-in
/// and publishes the helper heartbeat. All callbacks are delivered on the main queue.
final class SessionClient {
    struct Update {
        var state: PluginState?
        /// Non-nil only when a frame newer than the last delivered one is available.
        var newFrame: (data: Data, frame: PluginState.Frame)?
    }

    var onUpdate: ((Update) -> Void)?

    let directory: URL
    private let log = Logger(subsystem: "com.lrcscopes.helper", category: "session")
    private let ioQueue = DispatchQueue(label: "com.lrcscopes.helper.session-io")
    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var lastStateData: Data?
    private var lastFrameSeq = Int.min
    private var lastFramePhotoId: Int?
    /// The plug-in replaces state.json with delete + move (Lightroom's sandbox has no
    /// atomic replace), so the file can be briefly absent. Only report "no plug-in"
    /// once it has been missing for a while.
    private var stateMissingSince: Date?
    private static let missingStateGrace: TimeInterval = 3
    private let version: String

    init(directory: URL, version: String) {
        self.directory = directory
        self.version = version
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: directory.path])
        }
        // Renames into the directory modify the directory vnode -> `.write`.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write,
                                                               queue: ioQueue)
        source.setEventHandler { [weak self] in self?.poll() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source

        // A slow timer covers heartbeat publishing and staleness changes (state that
        // changes with time, not with files), and is a safety net for missed events.
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now(), repeating: SessionProtocol.pluginHeartbeatInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            self?.writeHeartbeat()
            self?.poll(forceStateDelivery: true)
        }
        t.resume()
        timer = t
        log.info("Watching session directory \(self.directory.path, privacy: .public)")
    }

    func stop() {
        dirSource?.cancel(); dirSource = nil
        timer?.cancel(); timer = nil
        ioQueue.sync {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(SessionProtocol.helperFileName))
        }
    }

    /// Asks for the current frame to be delivered again (e.g. after the UI was rebuilt).
    func redeliverCurrentFrame() {
        ioQueue.async { [weak self] in
            self?.lastFrameSeq = Int.min
            self?.poll(forceStateDelivery: true)
        }
    }

    // MARK: - IO queue

    private func poll(forceStateDelivery: Bool = false) {
        let stateURL = directory.appendingPathComponent(SessionProtocol.stateFileName)
        guard let data = try? Data(contentsOf: stateURL) else {
            let since = stateMissingSince ?? Date()
            stateMissingSince = since
            if forceStateDelivery, Date().timeIntervalSince(since) > Self.missingStateGrace {
                lastStateData = nil
                deliver(Update(state: nil, newFrame: nil))
            }
            return
        }
        stateMissingSince = nil
        if data == lastStateData && !forceStateDelivery { return }
        lastStateData = data

        let state: PluginState
        do {
            state = try PluginState.decode(data)
        } catch {
            log.error("Unreadable state.json: \(String(describing: error), privacy: .public)")
            return
        }
        guard state.protocol == SessionProtocol.version else {
            log.error("Protocol mismatch: plug-in \(state.protocol), helper \(SessionProtocol.version)")
            deliver(Update(state: nil, newFrame: nil))
            return
        }

        var update = Update(state: state, newFrame: nil)
        if let frame = state.frame, frame.seq != lastFrameSeq, PluginState.isSafeFrameFileName(frame.file) {
            let url = directory.appendingPathComponent(frame.file)
            if let jpeg = try? Data(contentsOf: url, options: .mappedIfSafe) {
                lastFrameSeq = frame.seq
                lastFramePhotoId = frame.photoId
                update.newFrame = (jpeg, frame)
            } else {
                // The plug-in prunes old frames; a missing file just means a newer
                // state.json is on its way.
                log.debug("Frame \(frame.file, privacy: .public) not readable yet")
            }
        }
        deliver(update)
    }

    private func deliver(_ update: Update) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
    }

    private func writeHeartbeat() {
        let state = HelperState(pid: ProcessInfo.processInfo.processIdentifier, version: version,
                                heartbeat: Date().timeIntervalSinceReferenceDate)
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = directory.appendingPathComponent(SessionProtocol.helperFileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Could not write heartbeat: \(String(describing: error), privacy: .public)")
        }
    }
}
