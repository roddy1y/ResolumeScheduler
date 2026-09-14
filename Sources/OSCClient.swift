import Foundation
import Network

/// Minimal OSC 1.0 UDP sender (big-endian, padded strings/blobs).
final class OSCClient: @unchecked Sendable {
    private var host: String
    private var port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "resolume.scheduler.osc")

    private(set) var isConnected = false
    private(set) var lastError: String?

    var endpointDescription: String { "\(host):\(port)" }

    init(host: String = "127.0.0.1", port: UInt16 = 7000) {
        self.host = host
        self.port = port
    }

    func reconnect(host: String, port: UInt16) {
        self.host = host
        self.port = max(1, port)
        connect()
    }

    func connect() {
        connection?.cancel()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Porta OSC non valida"
            isConnected = false
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.lastError = nil
            case .failed(let error):
                self.isConnected = false
                self.lastError = error.localizedDescription
            case .cancelled:
                self.isConnected = false
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    @discardableResult
    func sendInt(_ address: String, value: Int32 = 1) -> Bool {
        guard let connection else {
            lastError = "OSC non connesso"
            return false
        }
        let packet = Self.encodeMessage(address: address, intValue: value)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.lastError = error.localizedDescription
            }
        })
        return true
    }

    static func encodeMessage(address: String, intValue: Int32) -> Data {
        var data = Data()
        data.append(oscString(address))
        data.append(oscString(",i"))
        var be = intValue.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        return data
    }

    private static func oscString(_ string: String) -> Data {
        var bytes = Array(string.utf8)
        bytes.append(0)
        while bytes.count % 4 != 0 {
            bytes.append(0)
        }
        return Data(bytes)
    }
}
