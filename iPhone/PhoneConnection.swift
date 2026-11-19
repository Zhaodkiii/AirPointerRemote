import CoreBluetooth
import CryptoKit
import UIKit

struct NearbyMac: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    var id: UUID { peripheral.identifier }
}

final class PhoneConnection: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var nearby: [NearbyMac] = []
    @Published var connected = false
    @Published var bluetoothReady = false
    @Published var connecting = false
    @Published var status = "Checking Bluetooth…"
    @Published var macName = "Choose Your Mac"
    @Published var pairingCode: String?
    @Published var changedMac: NearbyMac?
    @Published var accessibility = false
    @Published var macPaused = false
    var onDisconnect: (() -> Void)?

    private let identity = try? PhoneKeychain.identity()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private var clientHello: PhoneProtocol.Hello?
    private var serverHello: PhoneProtocol.Hello?
    private var sessionKey: SymmetricKey?
    private var assembler = PhoneAssembler()
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var messageID: UInt16 = 0
    private var commands: [PhoneProtocol.Command] = []
    private var chunks: [Data] = []
    private var writing = false
    private var readingHandshake = false
    private var pendingMove = CGPoint.zero
    private var pendingMoveTime = 0.0
    private var lastWrite = 0.0
    private var lastStatus = 0.0
    private var tickTimer: Timer?
    private var foreground = true
    private var shouldReconnect = true
    private var handshakeStarted = 0.0
    private var sessionOrigin = 0.0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func connect(_ mac: NearbyMac) {
        changedMac = nil
        disconnect(reconnect: false)
        shouldReconnect = true
        macName = mac.name
        connecting = true
        status = "Connecting to \(mac.name)…"
        peripheral = mac.peripheral
        mac.peripheral.delegate = self
        central.stopScan()
        central.connect(mac.peripheral)
        handshakeStarted = ProcessInfo.processInfo.systemUptime
        sessionOrigin = handshakeStarted
    }

    func confirmPairing() {
        guard pairingCode != nil else { return }
        status = "iPhone confirmed. On your Mac, choose Codes Match — Allow for \(pairingCode ?? sessionKey.map(PhoneProtocol.code) ?? "")"
        pairingCode = nil
        enqueue(.init(.confirm), requiresReady: false)
    }

    func rejectPairing() { disconnect(reconnect: false) }

    func disconnect(reconnect: Bool = false, message: String? = nil) {
        shouldReconnect = reconnect
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearSession()
        if foreground { scan() }
        if let message { status = message }
    }

    func retryChangedMac() {
        guard let mac = changedMac else { return }
        PhoneKeychain.remove("mac." + mac.id.uuidString)
        if UserDefaults.standard.string(forKey: "phone.macID") == mac.id.uuidString {
            UserDefaults.standard.removeObject(forKey: "phone.macID")
            UserDefaults.standard.removeObject(forKey: "phone.macName")
        }
        connect(mac)
    }

    func forget() {
        changedMac = nil
        if let id = UserDefaults.standard.string(forKey: "phone.macID") { PhoneKeychain.remove("mac." + id) }
        UserDefaults.standard.removeObject(forKey: "phone.macID")
        UserDefaults.standard.removeObject(forKey: "phone.macName")
        disconnect()
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            scan()
        } else {
            // Cancellation plus the Mac watchdog releases any in-flight button-down.
            disconnect(reconnect: shouldReconnect)
            central.stopScan()
        }
    }

    func move(x: Double, y: Double, time: Double) {
        guard connected, !macPaused else { return }
        pendingMove.x += x
        pendingMove.y += y
        pendingMoveTime = time
    }

    func discardMovement() { pendingMove = .zero }

    func send(_ command: PhoneProtocol.Command) { enqueue(command, requiresReady: true) }

    private func enqueue(_ command: PhoneProtocol.Command, requiresReady: Bool) {
        guard sessionKey != nil, !requiresReady || connected else { return }
        if [.stop, .pause, .disconnect].contains(command.action) {
            commands.removeAll()
            chunks.removeAll()
            pendingMove = .zero
        }
        if command.action == .heartbeat, commands.contains(where: { $0.action == .heartbeat }) { return }
        if command.action == .scroll, command.phase == 2,
           let last = commands.last, last.action == .scroll, last.phase == 2 {
            commands[commands.count - 1] = .init(.scroll, x: last.x + command.x, y: last.y + command.y, time: command.time, phase: 2)
            return
        }
        guard commands.count < 64 else {
            disconnect(message: "Connection is busy. Control stopped. Select your Mac to retry.")
            return
        }
        // Flush preceding motion before button transitions, preserving gesture order.
        if pendingMove != .zero,
           [.leftDown, .leftUp, .rightClick, .doubleClick].contains(command.action) {
            commands.append(.init(.move, x: pendingMove.x, y: pendingMove.y, time: pendingMoveTime))
            pendingMove = .zero
        }
        commands.append(command)
        pump()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if connecting, now - handshakeStarted > 90 {
            disconnect(message: "Connection timed out. Open the Mac app and try again.")
            return
        }
        guard connected, foreground else { return }
        if now - lastStatus > 4 {
            disconnect(reconnect: true, message: "Mac stopped responding. Reconnecting…")
            return
        }
        pump()
        // Motion already keeps the receiver alive. Send heartbeats only while idle,
        // without pulling movement into the acknowledged queue.
        if now - lastWrite > 0.1, !writing, commands.isEmpty, chunks.isEmpty {
            enqueue(.init(.heartbeat), requiresReady: true)
        }
    }

    private func pump() {
        guard let peripheral, let input, !writing else { return }
        if !chunks.isEmpty {
            writing = true
            lastWrite = ProcessInfo.processInfo.systemUptime
            peripheral.writeValue(chunks.removeFirst(), for: input, type: .withResponse)
            return
        }
        guard let sessionKey else { return }
        if !commands.isEmpty {
            var command = commands.removeFirst()
            command.time -= sessionOrigin
            sent += 1
            guard let data = try? PhoneProtocol.seal(command.data, key: sessionKey, sequence: sent, direction: 2) else { return }
            queueReliable(data)
            return
        }
        guard pendingMove != .zero, peripheral.canSendWriteWithoutResponse else { return }
        let command = PhoneProtocol.Command(.move, x: pendingMove.x, y: pendingMove.y, time: pendingMoveTime - sessionOrigin)
        pendingMove = .zero
        sent += 1
        guard let data = try? PhoneProtocol.seal(command.data, key: sessionKey, sequence: sent, direction: 2) else { return }
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        messageID &+= 1
        let fragments = PhoneProtocol.fragments(data, mtu: mtu, id: messageID)
        if fragments.count == 1 {
            lastWrite = ProcessInfo.processInfo.systemUptime
            peripheral.writeValue(fragments[0], for: input, type: .withoutResponse)
        } else {
            queueReliable(data)
        }
    }

    private func queueReliable(_ data: Data) {
        guard let peripheral else { return }
        messageID &+= 1
        chunks += PhoneProtocol.fragments(data, mtu: peripheral.maximumWriteValueLength(for: .withResponse), id: messageID)
        pump()
    }

    private func scan() {
        guard foreground, central.state == .poweredOn, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [CBUUID(string: PhoneProtocol.service)])
        status = "Select a nearby Mac or wait for your paired Mac."
    }

    private func clearSession() {
        onDisconnect?()
        connected = false
        accessibility = false
        macPaused = false
        connecting = false
        peripheral = nil
        input = nil
        output = nil
        sessionKey = nil
        clientHello = nil
        serverHello = nil
        assembler = PhoneAssembler()
        pairingCode = nil
        sent = 0; received = 0
        lastWrite = 0
        writing = false
        readingHandshake = false
        chunks.removeAll()
        commands.removeAll()
        pendingMove = .zero
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        #if targetEnvironment(simulator)
        status = "Bluetooth control requires a physical iPhone."
        #else
        bluetoothReady = central.state == .poweredOn
        guard identity != nil else {
            status = "Could not access secure storage. Reopen the app and try again."
            return
        }
        switch central.state {
        case .poweredOn: scan()
        case .unauthorized: clearSession(); status = "Allow Bluetooth for AirPointer Remote in iPhone Settings."
        case .poweredOff: clearSession(); status = "Turn on Bluetooth in Settings."
        case .unsupported: clearSession(); status = "Bluetooth control is unavailable on this device."
        default: status = "Preparing Bluetooth…"
        }
        #endif
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Mac"
        if !nearby.contains(where: { $0.id == peripheral.identifier }) { nearby.append(.init(peripheral: peripheral, name: name)) }
        if shouldReconnect, UserDefaults.standard.string(forKey: "phone.macID") == peripheral.identifier.uuidString {
            connect(.init(peripheral: peripheral, name: name))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        peripheral.discoverServices([CBUUID(string: PhoneProtocol.service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        clearSession(); scan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        clearSession()
        status = "Disconnected"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: PhoneProtocol.service) }) else {
            disconnect(message: "Could not find AirPointer Remote on this Mac. Open the Mac app and try again.")
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: PhoneProtocol.input), CBUUID(string: PhoneProtocol.output)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        input = service.characteristics?.first { $0.uuid == CBUUID(string: PhoneProtocol.input) }
        output = service.characteristics?.first { $0.uuid == CBUUID(string: PhoneProtocol.output) }
        guard input != nil, let output else {
            disconnect(message: "Update AirPointer Remote on the Mac, then try again.")
            return
        }
        peripheral.setNotifyValue(true, for: output)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, characteristic.isNotifying else { disconnect(message: "Bluetooth setup failed. Select the Mac to retry."); return }
        guard let identity else { return }
        let hello = PhoneProtocol.Hello(name: UIDevice.current.name, publicKey: identity.publicKey.rawRepresentation, nonce: PhoneProtocol.nonce())
        clientHello = hello
        guard let data = try? JSONEncoder().encode(hello) else { return }
        status = "Waiting for the Mac pairing code…"
        print("Pairing: subscribed to Mac notifications; sending iPhone hello.")
        queueReliable(Data([1]) + data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        writing = false
        guard error == nil else { disconnect(reconnect: true, message: "Bluetooth was interrupted. Reconnecting…"); return }
        if chunks.isEmpty, sessionKey == nil, clientHello != nil, !readingHandshake,
           let output, output.properties.contains(.read) {
            readingHandshake = true
            print("Pairing: reading Mac handshake reply.")
            peripheral.readValue(for: output)
        }
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { pump() }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let chunk = characteristic.value else {
            if sessionKey == nil { print("Pairing: Mac reply read failed: \(String(describing: error)).") }
            return
        }
        // This characteristic can deliver both framed notifications and the raw
        // handshake reply when the iPhone explicitly reads it.
        guard let packet = chunk.first == 1 ? chunk : assembler.append(chunk) else { return }
        if packet.first == 1 {
            print("Pairing: received Mac handshake reply.")
            guard let identity, sessionKey == nil, let clientHello,
                  let server = try? JSONDecoder().decode(PhoneProtocol.Hello.self, from: packet.dropFirst()),
                  server.version == 1, server.publicKey.count == 32, server.nonce.count == 32,
                  let key = try? PhoneProtocol.session(privateKey: identity, client: clientHello, server: server, serverSide: false) else { return }
            let account = "mac." + peripheral.identifier.uuidString
            if let pin = PhoneKeychain.read(account), pin != server.publicKey {
                print("Pairing: saved Mac identity differs; asking the user to re-pair.")
                changedMac = NearbyMac(peripheral: peripheral, name: macName)
                disconnect(message: "This Mac’s identity has changed. Re-pair only if this is your Mac.")
                return
            }
            serverHello = server
            sessionKey = key
            print("Pairing: validated Mac reply; pairing code available.")
            macName = server.name
            handshakeStarted = ProcessInfo.processInfo.systemUptime
            pairingCode = PhoneProtocol.code(key)
            status = "Compare the codes on your iPhone and Mac."
            // A saved pin authenticates a reconnect without another pairing dialog.
            if PhoneKeychain.read(account) == server.publicKey { confirmPairing() }
            return
        }
        guard let key = sessionKey,
              let (sequence, data) = try? PhoneProtocol.open(packet, key: key, after: received, direction: 3),
              let update = try? JSONDecoder().decode(PhoneProtocol.Status.self, from: data) else { return }
        received = sequence
        lastStatus = ProcessInfo.processInfo.systemUptime
        accessibility = update.accessibility
        macPaused = update.paused
        switch update.state {
        case "ready":
            if !connected {
                guard let serverHello else { return }
                guard PhoneKeychain.save(serverHello.publicKey, account: "mac." + peripheral.identifier.uuidString) else {
                    disconnect(message: "Could not save this pairing on iPhone. Try again.")
                    return
                }
                UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "phone.macID")
                UserDefaults.standard.set(update.name, forKey: "phone.macName")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            macName = update.name
            connected = true
            connecting = false
            pairingCode = nil
            status = update.paused ? "Control is paused. If paused on the Mac, resume from its menu bar." : update.accessibility ? "Connected. You can control the pointer." : "On the Mac, allow AirPointer Remote in System Settings → Privacy & Security → Accessibility."
        case "confirm": break
        default:
            disconnect(message: update.state == "denied" ? "Pairing was declined on the Mac." : "Control stopped. Select the Mac to reconnect.")
        }
    }
}
