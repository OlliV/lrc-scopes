import Foundation

/// The file-based protocol between the Lightroom plug-in (Lua) and this helper.
///
/// Both sides share one *session directory*. Every file is written to a temporary
/// name and then `rename(2)`d into place, so readers never observe partial files.
///
///   plug-in  -> `state.json`        current Lightroom state + latest frame (see `PluginState`)
///   plug-in  -> `frame-<seq>.jpg`   rendered preview of the target photo, current develop settings
///   helper   -> `helper.json`       written/refreshed every second; its mtime is the helper heartbeat
///
/// Times are seconds since 2001-01-01 00:00 UTC, which is both `LrDate.currentTime()`
/// in Lua and `Date.timeIntervalSinceReferenceDate` in Swift.
public enum SessionProtocol {
    public static let version = 1
    public static let stateFileName = "state.json"
    public static let helperFileName = "helper.json"

    /// The plug-in refreshes its heartbeat at least this often.
    public static let pluginHeartbeatInterval: TimeInterval = 1
    /// Beyond this the plug-in is considered gone (Lightroom busy, crashed, plug-in disabled).
    public static let pluginStaleAfter: TimeInterval = 6

    /// Default session directory, used when the helper is started without `--session-dir`.
    /// Must match `SessionFiles.lua`.
    public static var defaultSessionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.lrcscopes.session", isDirectory: true)
    }
}

public struct PluginState: Codable, Equatable {
    public struct Photo: Codable, Equatable {
        public var id: Int
        public var name: String?
    }

    public struct Frame: Codable, Equatable {
        public var seq: Int
        public var file: String
        public var photoId: Int
        public var width: Int?
        public var height: Int?
    }

    public var `protocol`: Int
    public var pluginVersion: String?
    public var heartbeat: Double
    /// False when the user chose "Hide Scopes" in Lightroom.
    public var enabled: Bool
    /// True when the plug-in asks the helper to exit (plug-in shutdown / app quit).
    public var quit: Bool?
    /// Lightroom module name as returned by `LrApplicationView.getCurrentModuleName()`.
    public var module: String?
    public var photo: Photo?
    public var frame: Frame?

    public static func decode(_ data: Data) throws -> PluginState {
        try JSONDecoder().decode(PluginState.self, from: data)
    }

    public func isFresh(now: Double = Date().timeIntervalSinceReferenceDate) -> Bool {
        now - heartbeat <= SessionProtocol.pluginStaleAfter
    }

    public var isInDevelop: Bool { module == "develop" }

    /// Frame file names come from the session directory listing; refuse anything that
    /// could escape the directory.
    public static func isSafeFrameFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.hasSuffix(".jpg")
    }
}

public struct HelperState: Codable, Equatable {
    public var `protocol`: Int = SessionProtocol.version
    public var pid: Int32
    public var version: String
    public var heartbeat: Double

    public init(pid: Int32, version: String, heartbeat: Double) {
        self.pid = pid
        self.version = version
        self.heartbeat = heartbeat
    }
}
