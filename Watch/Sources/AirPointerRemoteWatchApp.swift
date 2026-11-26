import CoreBluetooth
import CoreMotion
import SwiftUI
import WatchKit

// Must match the Mac receiver.
let serviceUUID = CBUUID(string: "6B1E0001-9F4C-4C2A-9B8E-3D2A1C0F5E01")
let inputUUID = CBUUID(string: "6B1E0002-9F4C-4C2A-9B8E-3D2A1C0F5E01")
/// Subscribing to this tells the Mac the moment the watch connects or disconnects. (It sends nothing back.)
let outputUUID = CBUUID(string: "6B1E0003-9F4C-4C2A-9B8E-3D2A1C0F5E01")

@main
struct AirPointerRemoteWatchApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

/// Packets: [kind, Int16 LE a, Int16 LE b].
/// `.aim`: where the watch's 12 o'clock edge points, relative to "Center", in hundredths of a degree
/// (a = turned left, b = tipped up), then UInt16 LE: when it was measured, in ms on the watch's clock (wraps).
/// The Mac smooths with those times; Bluetooth delivers samples in bursts, so arrival times are useless.
/// `.pause`: a = 1 paused, 0 resumed.
/// `.info`: [kind, JSON] with the watch's model id, watchOS, battery and name (not the fixed 5 bytes).
/// `.drag`: a = 1 grab (mouse down), 0 drop (mouse up).
/// Clicks and drags may add the same UInt16 ms time as `.aim`: when the thumb touched down (or lifted, for a drop).
enum Kind: UInt8 { case aim = 0, leftClick = 1, rightClick = 2, scroll = 3, center = 4, pause = 5, info = 6, drag = 7 }

/// How long you hold the screen before it grabs. The Mac uses the same number to undo the press's jolt.
let holdToDrag = 0.35

/// A Mac running the receiver, seen nearby.
struct FoundMac: Identifiable {
    let id: UUID
    let name: String
    let peripheral: CBPeripheral
}

final class Pointer: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var connected = false
    @Published var receiverStatus = String(localized: "Open GlideCue Remote on your Mac.")
    private var foreground = false

    func setActive(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        if active {
            startMotion()
            start()
        } else {
            send(.pause, 1)
            central.stopScan()
            if let mac { central.cancelPeripheralConnection(mac) }
            motion.stopDeviceMotionUpdates()
            lastTimestamp = nil
            reset()
        }
    }
    @Published var paused = false
    /// Macs nearby you can pair with (only while nothing is paired).
    @Published var found: [FoundMac] = []
    /// The Mac you paired with. The watch only ever connects to this one until you forget it.
    @Published var pairedName = UserDefaults.standard.string(forKey: "pairedMacName")
    private var pairedID = UserDefaults.standard.string(forKey: "pairedMacID").flatMap(UUID.init)

    private var central: CBCentralManager!
    private var mac: CBPeripheral?
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private let motion = CMMotionManager()

    private var heading = 0.0       // radians turned left since "Center"
    private var elevation = 0.0     // radians the top edge points above horizontal, right now
    private var elevationZero = 0.0 // elevation when "Center" was pressed
    private var lastTimestamp: TimeInterval?
    private var infoTimer: Timer?
    private var sessionOrigin = ProcessInfo.processInfo.systemUptime
    private var pendingScroll = 0.0 // Crown turn not sent yet, in pixels

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Whatever direction the watch points now becomes the middle of the screen.
    func center() {
        recenter()
        send(.center)
    }

    /// Paused: the cursor stays put (aim keeps tracking, so resuming lines up again).
    func togglePause() {
        pendingScroll = 0
        paused.toggle()
        send(.pause, paused ? 1 : 0)
    }

    private func recenter() {
        heading = 0
        elevationZero = elevation
    }

    /// Tells the Mac which watch this is. Sent on connect, then every minute for the battery level.
    private func sendInfo() {
        guard let mac, let input else { return }
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let info: [String: Any] = [
            "model": model,                                          // e.g. "Watch7,5"
            "os": device.systemVersion,
            "battery": device.batteryLevel < 0 ? -1 : Int((device.batteryLevel * 100).rounded()),
            "charging": device.batteryState == .charging || device.batteryState == .full,
            "name": String(device.name.prefix(40)),                  // kept short so it fits in one packet
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: info) else { return }
        mac.writeValue(Data([Kind.info.rawValue]) + json, for: input, type: .withResponse)
    }

    // MARK: Motion → aim

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100

        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let dt = lastTimestamp.map { min(data.timestamp - $0, 0.05) } ?? 0
            lastTimestamp = data.timestamp

            let g = data.gravity, r = data.rotationRate
            let n = max((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 1e-6)
            let up = (x: -g.x / n, y: -g.y / n, z: -g.z / n)
            // Up/down comes straight from gravity, so it never drifts.
            elevation = asin(min(max(up.y, -1), 1))
            // Left/right has no absolute reference, so add up every turn around the vertical axis.
            // No dead zone: dropping slow turns is what made the old version slide out of line.
            heading += (r.x * up.x + r.y * up.y + r.z * up.z) * dt

            guard foreground, connected else { return }
            flushScroll()
            guard !paused else { return }
            sendAim(at: data.timestamp)
        }
    }

    private func sendAim(at timestamp: TimeInterval) {
        guard let mac, let input, mac.canSendWriteWithoutResponse else { return } // link busy: the next sample replaces this one
        let left = Int16(clamping: Int((remainder(heading, 2 * .pi) * 180 / .pi * 100).rounded()))
        let upward = Int16(clamping: Int(((elevation - elevationZero) * 180 / .pi * 100).rounded()))
        let ms = UInt16(truncatingIfNeeded: Int64((timestamp - sessionOrigin) * 1000))
        let bytes = [Kind.aim.rawValue,
                     UInt8(truncatingIfNeeded: left), UInt8(truncatingIfNeeded: left >> 8),
                     UInt8(truncatingIfNeeded: upward), UInt8(truncatingIfNeeded: upward >> 8),
                     UInt8(truncatingIfNeeded: ms), UInt8(truncatingIfNeeded: ms >> 8)]
        mac.writeValue(Data(bytes), for: input, type: .withoutResponse)
    }

    /// `at`: when it happened on the watch's clock (same clock as the motion samples). Clicks and drags send the
    /// moment the thumb touched down, so the Mac clicks where you were pointing then, before the tap jolted the watch.
    /// Each Crown event is a tiny fraction; keep the leftovers so slow turns still add up to scrolling.
    func scroll(by pixels: Double) {
        guard connected, !paused else { return }
        pendingScroll += pixels
        flushScroll()
    }

    /// Sent on the fast lane like aim samples, so scrolling never queues behind clicks. If the link is busy,
    /// the amount waits and goes with the next one (the motion loop retries 100 times a second).
    private func flushScroll() {
        let whole = Int16(clamping: Int(pendingScroll))
        guard whole != 0, let mac, let input, mac.canSendWriteWithoutResponse else { return }
        pendingScroll -= Double(whole)
        let bytes = [Kind.scroll.rawValue, UInt8(truncatingIfNeeded: whole), UInt8(truncatingIfNeeded: whole >> 8), 0, 0]
        mac.writeValue(Data(bytes), for: input, type: .withoutResponse)
    }

    func send(_ kind: Kind, _ a: Int16 = 0, _ b: Int16 = 0, at time: TimeInterval? = nil) {
        guard let mac, let input else { return }
        var bytes = [kind.rawValue,
                     UInt8(truncatingIfNeeded: a), UInt8(truncatingIfNeeded: a >> 8),
                     UInt8(truncatingIfNeeded: b), UInt8(truncatingIfNeeded: b >> 8)]
        if let time {
            let ms = UInt16(truncatingIfNeeded: Int64((time - sessionOrigin) * 1000))
            bytes += [UInt8(truncatingIfNeeded: ms), UInt8(truncatingIfNeeded: ms >> 8)]
        }
        // Clicks must not be dropped; aim samples can be.
        mac.writeValue(Data(bytes), for: input, type: kind == .aim ? .withoutResponse : .withResponse)
    }

    // MARK: Bluetooth

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: start()
        case .poweredOff: reset(); receiverStatus = String(localized: "Turn on Bluetooth on Apple Watch.")
        case .unauthorized: reset(); receiverStatus = String(localized: "Allow Bluetooth access for GlideCue Remote in Settings.")
        case .unsupported: reset(); receiverStatus = String(localized: "Bluetooth control requires a physical Apple Watch.")
        default: break
        }
    }

    /// Paired: wait for that Mac (the connect completes whenever it's in range). Not paired: list what's nearby.
    private func start() {
        guard foreground, central.state == .poweredOn, mac == nil else { return }
        found = []
        receiverStatus = pairedID == nil ? String(localized: "Open GlideCue Remote on your Mac.") : String(localized: "Waiting for your Mac. Keep the Mac app open.")
        if let pairedID, let known = central.retrievePeripherals(withIdentifiers: [pairedID]).first {
            connect(to: known)
        }
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        if let pairedID {
            if peripheral.identifier == pairedID { connect(to: peripheral) }
            return
        }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Mac"
        guard !found.contains(where: { $0.id == peripheral.identifier }) else { return }
        found.append(FoundMac(id: peripheral.identifier, name: name, peripheral: peripheral))
    }

    /// Pair with this Mac: remember it, then connect.
    func pair(_ found: FoundMac) {
        pairedID = found.id
        pairedName = found.name
        UserDefaults.standard.set(found.id.uuidString, forKey: "pairedMacID")
        UserDefaults.standard.set(found.name, forKey: "pairedMacName")
        self.found = []
        connect(to: found.peripheral)
    }

    /// Unpair, drop the connection and go back to listing nearby Macs.
    func forget() {
        pairedID = nil
        pairedName = nil
        UserDefaults.standard.removeObject(forKey: "pairedMacID")
        UserDefaults.standard.removeObject(forKey: "pairedMacName")
        if let mac { central.cancelPeripheralConnection(mac) }
        reset()
    }

    private func connect(to peripheral: CBPeripheral) {
        guard mac == nil else { return }
        central.stopScan()
        mac = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard mac === peripheral else { return }
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard mac === peripheral else { return }
        reset()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard mac === peripheral else { return }
        reset()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard mac === peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            receiverStatus = String(localized: "GlideCue Remote is unavailable on this Mac. Open the Mac app and try again.")
            return
        }
        peripheral.discoverCharacteristics([inputUUID, outputUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard mac === peripheral else { return }
        input = service.characteristics?.first { $0.uuid == inputUUID }
        output = service.characteristics?.first { $0.uuid == outputUUID }
        guard error == nil, input != nil, let output else {
            receiverStatus = String(localized: "Update GlideCue Remote on your Mac, then reconnect.")
            return
        }
        peripheral.setNotifyValue(true, for: output)
        receiverStatus = String(localized: "Approve the Apple Watch connection on your Mac.")
        sessionOrigin = ProcessInfo.processInfo.systemUptime
        recenter()
        infoTimer?.invalidate()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sendInfo() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard mac === peripheral, characteristic.uuid == outputUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            receiverStatus = String(localized: "Could not connect. Forget this Mac and try again.")
            return
        }
        // Request approval once; motion starts after the receiver confirms it.
        sendInfo()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard foreground, mac === peripheral, characteristic.uuid == outputUUID,
              error == nil, let value = characteristic.value, value.count == 1, let state = value.first else { return }
        switch state {
        case 0: receiverStatus = String(localized: "Approve the Apple Watch connection on your Mac."); sendInfo()
        case 1: receiverStatus = String(localized: "Connected"); if !connected { recenter(); sendInfo() }
        case 2: receiverStatus = String(localized: "Allow GlideCue Remote in Mac Accessibility settings.")
        case 3: receiverStatus = String(localized: "Control is paused. Resume it from the Mac menu bar.")
        case 4: receiverStatus = String(localized: "Connection declined on Mac. Forget this Mac to try again.")
        case 5: receiverStatus = String(localized: "Another device has control. Disconnect it to use Apple Watch.")
        default: return
        }
        connected = state == 1
    }

    private func reset() {
        mac = nil
        input = nil
        output = nil
        connected = false
        paused = false
        pendingScroll = 0
        infoTimer?.invalidate()
        start()
    }
}
