import Foundation
import Network
import XCTest
@testable import LRCScopes
import ScopesCore

/// A loopback TCP server standing in for the plug-in's "send" LrSocket.
private final class FakeLrSocket {
    let queue = DispatchQueue(label: "fake-lrsocket")
    private var listener: NWListener!
    private var client: NWConnection?
    private(set) var port: UInt16 = 0
    var onClient: (() -> Void)?

    init(port: UInt16 = 0) throws {
        try listen(port: port)
    }

    private func listen(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            self?.client = c
            c.stateUpdateHandler = { if case .ready = $0 { self?.onClient?() } }
            c.start(queue: self!.queue)
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        self.port = listener.port!.rawValue
    }

    func send(_ text: String) {
        client?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    /// Sends a line in many small writes, as TCP may deliver it.
    func sendChunked(_ text: String, chunk: Int) {
        let data = Data(text.utf8)
        for start in stride(from: 0, to: data.count, by: chunk) {
            client?.send(content: data.subdata(in: start..<min(data.count, start + chunk)), completion: .contentProcessed { _ in })
        }
    }

    func dropClientAndStop() {
        client?.cancel()
        client = nil
        listener.cancel()
    }

    func restart() throws { try listen(port: port) }
}

final class PluginConnectionTests: XCTestCase {
    func testReceivesMessagesReconnectsAndGivesUp() throws {
        let server = try FakeLrSocket()
        let connection = PluginConnection(port: server.port, giveUpAfter: 3)
        var events: [String] = []
        var frames: [Data] = []
        var waiters: [(String, XCTestExpectation)] = []
        connection.onEvent = { event in
            let name: String
            switch event {
            case .connected: name = "connected"
            case .disconnected: name = "disconnected"
            case .gaveUp: name = "gaveUp"
            case .message(let m):
                switch m {
                case .hello: name = "hello"
                case .state: name = "state"
                case .frame(let f): name = "frame"; frames.append(f.jpeg)
                case .previewError: name = "previewError"
                case .quit: name = "quit"
                }
            }
            events.append(name)
            waiters.removeAll { w in
                if w.0 == name { w.1.fulfill(); return true }
                return false
            }
        }
        func expect(_ name: String) -> XCTestExpectation {
            let e = expectation(description: name)
            waiters.append((name, e))
            return e
        }

        let connected = expect("connected")
        let clientArrived = expectation(description: "server saw client")
        server.onClient = { clientArrived.fulfill() }
        connection.start()
        wait(for: [connected, clientArrived], timeout: 5)
        server.onClient = nil

        // Exactly what Protocol.lua sends, including a large frame split into chunks.
        let jpeg = Data((0..<300_000).map { UInt8($0 % 253) })
        let gotFrame = expect("frame")
        let gotQuit = expect("quit")
        server.send(#"{"pluginVersion":"1.1.0","protocol":2,"type":"hello"}"# + "\n")
        server.send(#"{"enabled":true,"module":"develop","photo":{"id":1,"name":"A.CR3"},"type":"state"}"# + "\n")
        server.sendChunked(#"{"type":"frame","seq":1,"photoId":1,"jpeg":""# + jpeg.base64EncodedString() + "\"}\n", chunk: 7_000)
        server.send(#"{"type":"bogus"}"# + "\n" + #"{"type":"quit"}"# + "\n")
        wait(for: [gotFrame, gotQuit], timeout: 5)
        XCTAssertEqual(Array(events.prefix(4)), ["connected", "hello", "state", "frame"])
        XCTAssertEqual(frames.first, jpeg)
        XCTAssertFalse(events.contains("bogus"), "unknown message types are skipped")

        // Plug-in socket drops and comes back on the same port (LrSocket reconnect()).
        let disconnected = expect("disconnected")
        server.dropClientAndStop()
        wait(for: [disconnected], timeout: 5)
        let reconnected = expect("connected")
        let serverSawReconnect = expectation(description: "server saw reconnect")
        server.onClient = { serverSawReconnect.fulfill(); server.onClient = nil }
        try server.restart()
        wait(for: [reconnected, serverSawReconnect], timeout: 5)

        // Gone for good: the helper gives up (and the app then quits).
        let gaveUp = expect("gaveUp")
        server.dropClientAndStop()
        wait(for: [gaveUp], timeout: 10)
        connection.stop()
    }

    func testLaunchOptionsParse() {
        let o = LaunchOptions.parse(["LRCScopes", "--port", "51669", "-NSFoo", "YES"])
        XCTAssertEqual(o.port, 51669)
        XCTAssertFalse(o.alwaysShow)
        XCTAssertNil(LaunchOptions.parse(["LRCScopes", "--port", "0"]).port)
    }
}
