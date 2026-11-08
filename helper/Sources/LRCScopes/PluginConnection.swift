import Foundation
import Network
import os
import ScopesCore

/// TCP client for the Lightroom plug-in's `LrSocket` (see `WireProtocol`).
///
/// Connects to 127.0.0.1:<port>, splits the stream into lines and decodes messages.
/// If the connection drops it keeps retrying for `giveUpAfter`; the plug-in's socket
/// re-listens on the same port after a disconnect or timeout. Events are delivered on
/// the main queue.
final class PluginConnection {
    enum Event {
        case connected
        case message(PluginMessage)
        case disconnected
        /// No connection for `giveUpAfter`: Lightroom or the plug-in is gone.
        case gaveUp
    }

    var onEvent: ((Event) -> Void)?

    static let retryInterval: TimeInterval = 0.5
    private let giveUpAfter: TimeInterval

    private let port: NWEndpoint.Port
    private let log = Logger(subsystem: "com.lrcscopes.helper", category: "connection")
    private let queue = DispatchQueue(label: "com.lrcscopes.helper.connection")
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var disconnectedSince: Date? = Date()
    private var stopped = false
    private var isConnected = false

    init(port: UInt16, giveUpAfter: TimeInterval = 20) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.giveUpAfter = giveUpAfter
    }

    func start() {
        queue.async { self.connect() }
    }

    func stop() {
        queue.sync {
            stopped = true
            connection?.cancel()
            connection = nil
        }
    }

    // MARK: - Connection queue

    private func connect() {
        guard !stopped else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let c = NWConnection(host: "127.0.0.1", port: port, using: params)
        connection = c
        framer.reset()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.disconnectedSince = nil
                self.log.info("Connected to plug-in on port \(self.port.rawValue)")
                self.emit(.connected)
                self.receive(on: c)
            case .waiting(let error), .failed(let error):
                self.log.debug("Connection not available: \(String(describing: error), privacy: .public)")
                self.connectionLost()
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak c] data, _, isComplete, error in
            guard let self, let c, c === self.connection else { return }
            if let data, !data.isEmpty {
                do {
                    for line in try self.framer.append(data) {
                        self.handle(line: line)
                    }
                } catch {
                    self.log.error("Dropping oversized message from plug-in")
                }
            }
            if isComplete || error != nil {
                if let error { self.log.info("Connection ended: \(String(describing: error), privacy: .public)") }
                self.connectionLost()
            } else {
                self.receive(on: c)
            }
        }
    }

    private func handle(line: Data) {
        do {
            emit(.message(try PluginMessage.decode(line: line)))
        } catch {
            // Unknown or malformed messages are skipped, not fatal: a newer plug-in
            // may send message types this helper doesn't know.
            log.error("Ignoring message: \(String(describing: error), privacy: .public)")
        }
    }

    private func connectionLost() {
        connection?.cancel()
        connection = nil
        if isConnected {
            isConnected = false
            emit(.disconnected)
        }
        let since = disconnectedSince ?? Date()
        disconnectedSince = since
        guard !stopped else { return }
        if Date().timeIntervalSince(since) > giveUpAfter {
            log.info("Plug-in unreachable for \(self.giveUpAfter) s; giving up")
            stopped = true
            emit(.gaveUp)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in self?.connect() }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
