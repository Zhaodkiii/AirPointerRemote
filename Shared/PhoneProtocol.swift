import Foundation
import CryptoKit
import Security

/// Versioned protocol shared by the iPhone and Mac targets.
enum PhoneProtocol {
    static let input = "6B1E0012-9F4C-4C2A-9B8E-3D2A1C0F5E01"
    static let output = "6B1E0013-9F4C-4C2A-9B8E-3D2A1C0F5E01"
    static let service = "6B1E0001-9F4C-4C2A-9B8E-3D2A1C0F5E01"

    struct Hello: Codable {
        var version = 1
        let name: String
        let publicKey: Data
        let nonce: Data
    }

    struct Status: Codable {
        let state: String
        let name: String
        let accessibility: Bool
        let paused: Bool
    }

    // Heartbeat phases understood by receivers advertising background resume.
    enum LinkedLifecycle: UInt8 {
        case foreground = 1, background = 2
        static let grace: TimeInterval = 20
    }

    enum Action: UInt8 {
        case heartbeat, move, leftDown, leftUp, rightClick, doubleClick
        case scroll, stop, center, pause, resume, confirm, disconnect, linkStart, linkEnd, padGesture
        case resetPointer, linkedInput
    }

    enum PadGesture: UInt8, Codable {
        case zoomIn = 1, zoomOut, fit, rotateLeft, rotateRight, back, forward
        case previousSpace, nextSpace, notifications, missionControl, appWindows, apps, desktop

        var isSystemAction: Bool {
            switch self {
            case .previousSpace, .nextSpace, .notifications, .missionControl, .appWindows, .apps, .desktop: return true
            default: return false
            }
        }
    }

    struct Command {
        let action: Action
        var x: Double = 0
        var y: Double = 0
        var time: Double = ProcessInfo.processInfo.systemUptime
        var phase: UInt8 = 0

        var data: Data {
            var result = Data([action.rawValue, phase])
            for value in [x, y, time] { result.appendInteger(value.bitPattern) }
            return result
        }

        init(_ action: Action, x: Double = 0, y: Double = 0, time: Double = ProcessInfo.processInfo.systemUptime, phase: UInt8 = 0) {
            self.action = action; self.x = x; self.y = y; self.time = time; self.phase = phase
        }

        init?(data: Data) {
            guard data.count == 26, let action = Action(rawValue: data[0]) else { return nil }
            self.action = action
            phase = data[1]
            x = Double(bitPattern: data.integer(at: 2, as: UInt64.self))
            y = Double(bitPattern: data.integer(at: 10, as: UInt64.self))
            time = Double(bitPattern: data.integer(at: 18, as: UInt64.self))
            guard x.isFinite, y.isFinite, time.isFinite else { return nil }
        }
    }

    static func nonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    static func session(privateKey: Curve25519.KeyAgreement.PrivateKey, client: Hello, server: Hello, serverSide: Bool) throws -> SymmetricKey {
        let peer = serverSide ? client.publicKey : server.publicKey
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: client.nonce + server.nonce,
            sharedInfo: Data("WatchPointer iPhone v1".utf8) + client.publicKey + server.publicKey, outputByteCount: 32)
    }

    static func code(_ key: SymmetricKey) -> String {
        let digest = Data(HMAC<SHA256>.authenticationCode(for: Data("compare code".utf8), using: key))
        return String(format: "%06u", digest.integer(at: 0, as: UInt32.self) % 1_000_000)
    }

    static func seal(_ data: Data, key: SymmetricKey, sequence: UInt64, direction: UInt8) throws -> Data {
        var header = Data([direction])
        header.appendInteger(sequence)
        return header + (try ChaChaPoly.seal(data, using: key, authenticating: header)).combined
    }

    static func open(_ data: Data, key: SymmetricKey, after: UInt64, direction: UInt8) throws -> (UInt64, Data) {
        guard data.count >= 37, data[0] == direction else { throw ProtocolError.invalid }
        let sequence = data.integer(at: 1, as: UInt64.self)
        guard sequence > after else { throw ProtocolError.invalid }
        let plaintext = try ChaChaPoly.open(.init(combined: Data(data.dropFirst(9))), using: key, authenticating: Data(data.prefix(9)))
        return (sequence, plaintext)
    }

    enum ProtocolError: Error { case invalid }

    /// Fragment both handshake and encrypted messages for the negotiated ATT MTU.
    static func fragments(_ data: Data, mtu: Int, id: UInt16) -> [Data] {
        let capacity = max(1, mtu - 7)
        let count = (data.count + capacity - 1) / capacity
        guard count > 0, count <= 256, data.count <= 4096 else { return [] }
        return (0..<count).map { index in
            var chunk = Data([0xF0])
            chunk.appendInteger(id)
            chunk.appendInteger(UInt16(count))
            chunk.appendInteger(UInt16(index))
            chunk.append(data.dropFirst(index * capacity).prefix(capacity))
            return chunk
        }
    }
}

struct PhoneAssembler {
    private var identifier: UInt16?
    private var expected = 0
    private var next = 0
    private var buffer = Data()
    private var started = 0.0

    mutating func append(_ chunk: Data) -> Data? {
        guard chunk.count >= 7, chunk[0] == 0xF0 else { return nil }
        let id = chunk.integer(at: 1, as: UInt16.self)
        let count = Int(chunk.integer(at: 3, as: UInt16.self))
        let index = Int(chunk.integer(at: 5, as: UInt16.self))
        let now = ProcessInfo.processInfo.systemUptime
        if index == 0 {
            identifier = id; expected = count; next = 0; buffer = Data(); started = now
        }
        guard identifier == id, count == expected, count > 0, count <= 256,
              index == next, now - started < 10, buffer.count + chunk.count - 7 <= 4096 else {
            identifier = nil
            return nil
        }
        buffer.append(chunk.dropFirst(7))
        next += 1
        guard next == expected else { return nil }
        identifier = nil
        return buffer
    }
}

enum PhoneKeychain {
    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.daokaihua.airpointerremote.phone", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult static func save(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.daokaihua.airpointerremote.phone", kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.daokaihua.airpointerremote.phone", kSecAttrAccount as String: account] as CFDictionary)
    }

    static func identity() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = read("identity"), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) { return key }
        let key = Curve25519.KeyAgreement.PrivateKey()
        guard save(key.rawRepresentation, account: "identity") else {
            throw NSError(domain: "AirPointerRemote.Keychain", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法保存设备身份，请检查 App 签名和钥匙串访问权限"])
        }
        return key
    }
}

extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size { value |= T(self[offset + index]) << (index * 8) }
        return value
    }
}
