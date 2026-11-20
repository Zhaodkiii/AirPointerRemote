import CryptoKit
import Foundation
import Network
import Security

struct LinkedOffer {
    static let service = "_airpointer._tcp"
    let name: String
    let key: Data

    init(key: SymmetricKey, first: UInt32, second: UInt32) {
        var salt = Data()
        salt.appendInteger(first)
        salt.appendInteger(second)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt,
            info: Data("AirPointer Linked Screen TLS v1".utf8), outputByteCount: 32)
        self.key = derived.withUnsafeBytes { Data($0) }
        name = "AirPointer-" + SHA256.hash(data: self.key).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    var parameters: NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(name.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}

struct LinkedMessage: Codable {
    enum Kind: String, Codable {
        case viewing, alive, waiting, ready, focus, insert, inserted, rejected, stop, frameAck, keepAwake
        case click, doubleClick, rightClick, dragStart, dragMove, dragEnd, relative, scroll
        case currentClick, currentRight, currentDouble, currentDown, gesture
    }
    struct StyleRun: Codable {
        var start: Int
        var count: Int
        // Bits 0–2 represent bold, italic and underline.
        var style: Int
    }
    var styles: [StyleRun]?
    var selection: UUID?
    var readSelection: Bool?
    var composerVersion: Int?
    var keyboardClick: UUID?
    var scrollPhase: UInt8?
    var supportsGestures: Bool?
    var padGesture: PhoneProtocol.PadGesture?
    var backgroundResume: Bool?
    var pictureInPicture: Bool?
    var frameEnqueued: Bool?
    var videoDelayed: Bool?
    var videoBitrate: Int?
    var videoFPS: Int?
    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    var token: UUID?
    var request: UUID?
    var text: String?
    init(_ kind: Kind, x: Double = 0, y: Double = 0, token: UUID? = nil, request: UUID? = nil, text: String? = nil) {
        self.kind = kind; self.x = x; self.y = y; self.token = token; self.request = request; self.text = text
    }
}

/// Each connection is confined to its caller’s serial queue.
final class LinkedChannel {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((LinkedMessage) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false
    private static let limit = 4 * 1024 * 1024

    init(_ connection: NWConnection) { self.connection = connection }
    func start(queue: DispatchQueue = .main) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !closed else { return }
            switch state {
            case .ready: onReady?(); receiveHeader()
            case .failed(let error): close(error.localizedDescription)
            case .cancelled: close("Connection closed.")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: LinkedMessage) {
        if let data = try? JSONEncoder().encode(message) { send(data, frame: false) }
    }

    func send(_ payload: Data, frame: Bool) {
        guard !closed, payload.count < Self.limit else { return }
        var bytes = Data()
        bytes.appendInteger(UInt32(payload.count + 1))
        bytes.append(frame ? 1 : 0)
        bytes.append(payload)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error.localizedDescription) }
        })
    }

    func close(_ reason: String = "Sharing ended.") {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(reason)
    }

    private func receiveHeader() {
        read(4) { header in
            let length = Int(header.integer(at: 0, as: UInt32.self))
            guard (2...Self.limit).contains(length) else { self.close("Invalid message size."); return }
            self.read(length) { data in
                let payload = Data(data.dropFirst())
                if data.first == 1, let handle = self.onFrame { handle(payload) }
                else if data.first == 0, payload.count <= 128 * 1024,
                        let message = try? JSONDecoder().decode(LinkedMessage.self, from: payload) { self.onMessage?(message) }
                else { self.close("Unsupported sharing message."); return }
                self.receiveHeader()
            }
        }
    }

    private func read(_ length: Int, handle: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, !closed else { return }
            guard error == nil, let data, data.count == length else { close("Sharing connection lost."); return }
            handle(data)
        }
    }
}
