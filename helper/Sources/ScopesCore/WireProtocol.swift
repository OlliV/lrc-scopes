import Foundation

/// The protocol between the Lightroom plug-in (Lua) and this helper, over the
/// plug-in's `LrSocket`.
///
/// Transport: the plug-in binds a "send" mode `LrSocket` on 127.0.0.1 (system-chosen
/// port) and launches the helper with `--port <n>`; the helper connects as a TCP
/// client. Data flows plug-in -> helper only. The helper notices the plug-in going
/// away from the connection closing or `staleAfter`. The helper stays running for
/// the whole Lightroom session (closing the panel only hides it): re-arming an
/// LrSocket whose client has gone away deadlocks Lightroom, so the plug-in has to
/// bind a fresh socket whenever a helper is lost (`HelperLink.lua`).
///
/// Framing: one UTF-8 JSON object per line, terminated by `\n`. Empty lines are
/// ignored. Messages (see `PluginMessage`):
///
///   {"type":"hello","protocol":2,"pluginVersion":"1.1.0"}
///   {"type":"state","enabled":true,"module":"develop","photo":{"id":1,"name":"A.CR3"},"showSeq":0}
///   {"type":"frame","seq":7,"photoId":1,"renderMs":85,"sentAt":784249200.250,"jpeg":"<base64>"}
///   {"photoId":1,"reason":"error loading thumb","type":"previewError"}
///   {"type":"quit"}
///
/// The plug-in re-sends `state` at least every `keepaliveInterval`. Must match
/// `Protocol.lua`.
public enum WireProtocol {
    public static let version = 2
    public static let keepaliveInterval: TimeInterval = 1
    /// No message for this long means the plug-in is stuck (e.g. Lightroom busy).
    public static let staleAfter: TimeInterval = 6
    /// Upper bound for a single line; a 2048 px preview is well under 2 MB in base64.
    public static let maxLineLength = 32 * 1024 * 1024
}

public struct PluginState: Codable, Equatable {
    public struct Photo: Codable, Equatable {
        public var id: Int
        public var name: String?
    }

    /// False when the user chose "Hide Scopes" in Lightroom.
    public var enabled: Bool
    /// Lightroom module name as returned by `LrApplicationView.getCurrentModuleName()`.
    public var module: String?
    public var photo: Photo?
    /// Incremented each time the user chooses Show Scopes. Closing the panel only
    /// hides it (the helper must keep running; see `HelperLink.lua`); a new value
    /// re-opens it.
    public var showSeq: Int?

    public init(enabled: Bool, module: String?, photo: Photo?, showSeq: Int? = nil) {
        self.enabled = enabled
        self.module = module
        self.photo = photo
        self.showSeq = showSeq
    }

    public var isInDevelop: Bool { module == "develop" }
}

public struct FrameMessage: Equatable, Decodable {
    public var seq: Int
    public var photoId: Int
    public var jpeg: Data
    /// How long Lightroom took to render the preview (diagnostic).
    public var renderMs: Int?
    /// When the plug-in sent it, seconds since 2001-01-01 UTC (diagnostic).
    public var sentAt: Double?

    public init(seq: Int, photoId: Int, jpeg: Data, renderMs: Int? = nil, sentAt: Double? = nil) {
        self.seq = seq; self.photoId = photoId; self.jpeg = jpeg; self.renderMs = renderMs; self.sentAt = sentAt
    }
}

public enum PluginMessage: Equatable {
    case hello(protocol: Int, pluginVersion: String?)
    case state(PluginState)
    case frame(FrameMessage)
    /// Lightroom could not render a preview of this photo.
    case previewError(photoId: Int, reason: String?)
    case quit

    public enum DecodingError: Error, Equatable {
        case unknownType(String)
    }

    private struct Envelope: Decodable { var type: String }
    private struct Hello: Decodable { var `protocol`: Int; var pluginVersion: String? }
    private struct PreviewError: Decodable { var photoId: Int; var reason: String? }

    /// Decodes one line (without its terminator).
    public static func decode(line: Data) throws -> PluginMessage {
        let decoder = JSONDecoder() // Data fields are base64, the default strategy.
        let type = try decoder.decode(Envelope.self, from: line).type
        switch type {
        case "hello":
            let h = try decoder.decode(Hello.self, from: line)
            return .hello(protocol: h.protocol, pluginVersion: h.pluginVersion)
        case "state":
            return .state(try decoder.decode(PluginState.self, from: line))
        case "frame":
            return .frame(try decoder.decode(FrameMessage.self, from: line))
        case "previewError":
            let e = try decoder.decode(PreviewError.self, from: line)
            return .previewError(photoId: e.photoId, reason: e.reason)
        case "quit":
            return .quit
        default:
            throw DecodingError.unknownType(type)
        }
    }
}

/// Splits a byte stream into `\n`-terminated lines (a trailing `\r` is dropped).
public struct LineFramer {
    public enum FramingError: Error, Equatable { case lineTooLong }

    private var buffer = Data()
    /// Bytes of `buffer` already known to contain no newline (avoids rescanning a
    /// large frame line on every chunk).
    private var scanned = 0
    private let maxLineLength: Int

    public init(maxLineLength: Int = WireProtocol.maxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Appends received bytes and returns every complete, non-empty line.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        var searchFrom = buffer.startIndex + scanned
        while let nl = buffer[searchFrom...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            if end > start { lines.append(Data(buffer[start..<end])) }
            start = buffer.index(after: nl)
            searchFrom = start
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        // Re-base: `Data` slices keep their indices, a fresh copy starts at 0.
        buffer = Data(buffer)
        scanned = buffer.count
        if buffer.count > maxLineLength {
            reset()
            throw FramingError.lineTooLong
        }
        return lines
    }

    public mutating func reset() {
        buffer.removeAll()
        scanned = 0
    }
}
