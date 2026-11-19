import UIKit
import CoreMotion
import simd

final class RemoteController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case trackpad = "Trackpad", air = "Air Mouse", hybrid = "Hybrid"
        var id: String { rawValue }
    }

    let connection = PhoneConnection()
    @Published var mode: Mode = .trackpad { didSet { stop(); updateMotion() } }
    @Published var paused = false
    @Published var airHeld = false
    @Published var precise = false
    @Published var motionMessage: String?
    @Published var continuous = false { didSet { resetAir(); updateMotion() } }
    @Published var touchSpeed = UserDefaults.standard.object(forKey: "touchSpeed") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(touchSpeed, forKey: "touchSpeed") }
    }
    @Published var airSpeed = UserDefaults.standard.object(forKey: "airSpeed") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(airSpeed, forKey: "airSpeed") }
    }
    @Published var naturalScroll = UserDefaults.standard.object(forKey: "naturalScroll") as? Bool ?? true {
        didSet { UserDefaults.standard.set(naturalScroll, forKey: "naturalScroll") }
    }
    @Published var inertia = UserDefaults.standard.object(forKey: "inertia") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inertia, forKey: "inertia") }
    }
    private let motion = CMMotionManager()
    private var foreground = true
    private var interactionSuspended = false
    private var airFilter = AirMotionFilter()
    private var filteredTouchSpeed = 0.0
    private var lastTouchSample: TimeInterval?
    private var leftSources: Set<String> = []
    private var scrollVelocity = CGPoint.zero
    private var inertiaTimer: Timer?

    init() {
        connection.onDisconnect = { [weak self] in self?.resetLocal() }
    }

    var canControl: Bool { connection.connected && connection.accessibility && !connection.macPaused && !paused && foreground && !interactionSuspended }
    var airActive: Bool { canControl && mode != .trackpad && (airHeld || continuous) }

    func setForeground(_ active: Bool, inBackground: Bool) {
        foreground = active
        if !active && !connection.linkedRequested { stop() }
        if active || inBackground { connection.setForeground(active) }
        UIApplication.shared.isIdleTimerDisabled = active && connection.connected
        updateMotion()
    }

    func suspendInteraction(_ suspended: Bool) {
        stop()
        interactionSuspended = suspended
        updateMotion()
    }

    func connectionChanged() {
        resetLocal()
        UIApplication.shared.isIdleTimerDisabled = foreground && connection.connected
        updateMotion()
    }

    func togglePause() {
        stop()
        paused.toggle()
        connection.send(.init(paused ? .pause : .resume))
        updateMotion()
        haptic()
    }

    func setAirHeld(_ held: Bool) {
        cancelInertia()
        airHeld = held
        resetAir()
        if !held { connection.discardMovement() }
    }

    func calibrate() {
        stop()
        connection.send(.init(.center))
        resetAir()
        haptic()
    }

    func touchMoved(_ delta: CGPoint, velocity: CGPoint) {
        guard canControl, mode != .air, !airActive else { return }
        cancelInertia()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTouchSample.map { now - $0 } ?? 0
        let speed = hypot(velocity.x, velocity.y)
        if elapsed > 0, elapsed < 0.08 {
            let alpha = 1 - exp(-elapsed / 0.018)
            filteredTouchSpeed += alpha * (speed - filteredTouchSpeed)
        } else {
            filteredTouchSpeed = speed
        }
        lastTouchSample = now
        // A flat slow zone and a smooth ramp keep small corrections predictable.
        let ramp = min(max((filteredTouchSpeed - 90) / 950, 0), 1)
        let acceleration = ramp * ramp * (3 - 2 * ramp)
        let gain = touchSpeed * (precise ? 0.32 : 0.85 + acceleration)
        connection.move(x: delta.x * gain, y: delta.y * gain, time: now)
    }

    func beginTouchMovement() {
        cancelInertia()
        lastTouchSample = nil
        filteredTouchSpeed = 0
    }

    func click(right: Bool = false, double: Bool = false, touchTime: TimeInterval? = nil) {
        guard canControl else { return }
        cancelInertia()
        if right { connection.send(.init(.rightClick)) }
        else if double { connection.send(.init(.doubleClick)) }
        else {
            connection.send(.init(.leftDown, time: touchTime ?? ProcessInfo.processInfo.systemUptime, phase: airActive ? 1 : 0))
            connection.send(.init(.leftUp))
        }
        haptic()
    }

    func left(_ pressed: Bool, source: String) {
        guard !pressed || canControl else { return }
        cancelInertia()
        let wasHeld = !leftSources.isEmpty
        if pressed { leftSources.insert(source) } else { leftSources.remove(source) }
        let isHeld = !leftSources.isEmpty
        if wasHeld != isHeld {
            connection.send(.init(isHeld ? .leftDown : .leftUp, phase: airActive ? 1 : 0))
            if isHeld { haptic() }
        }
    }

    func scroll(_ delta: CGPoint, phase: UInt8) {
        guard canControl else { return }
        let sign = naturalScroll ? 1.0 : -1.0
        connection.send(.init(.scroll, x: delta.x * sign, y: delta.y * sign, phase: phase))
    }

    func beginScroll() { cancelInertia(); scroll(.zero, phase: 1) }

    func endScroll(velocity: CGPoint) {
        guard inertia, canControl, hypot(velocity.x, velocity.y) > 80 else { scroll(.zero, phase: 4); return }
        scrollVelocity = velocity
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, self.canControl else { self?.cancelInertia(); return }
            self.scrollVelocity.x *= 0.90
            self.scrollVelocity.y *= 0.90
            if hypot(self.scrollVelocity.x, self.scrollVelocity.y) < 15 {
                self.cancelInertia()
            } else {
                self.scroll(CGPoint(x: self.scrollVelocity.x / 60, y: self.scrollVelocity.y / 60), phase: 2)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        inertiaTimer = timer
    }

    func cancelInertia() {
        guard inertiaTimer != nil else { return }
        inertiaTimer?.invalidate()
        inertiaTimer = nil
        scroll(.zero, phase: 4)
    }

    func stop() {
        cancelInertia()
        connection.discardMovement()
        connection.send(.init(.stop))
        resetLocal()
    }

    private func resetLocal() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
        leftSources.removeAll()
        airHeld = false
        precise = false
        lastTouchSample = nil
        filteredTouchSpeed = 0
        resetAir()
    }

    private func resetAir() { airFilter.reset() }

    private func updateMotion() {
        motion.stopDeviceMotionUpdates()
        resetAir()
        guard foreground, !interactionSuspended, connection.connected, mode != .trackpad else { return }
        guard motion.isDeviceMotionAvailable else {
            motionMessage = "Motion control is unavailable on this device. Use Trackpad mode."
            return
        }
        motionMessage = nil
        motion.deviceMotionUpdateInterval = 0.01
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error { self.motionMessage = "Motion control is unavailable: \(error.localizedDescription)"; return }
            guard let data, self.airActive else { self.resetAir(); return }
            let q = data.attitude.quaternion
            let orientation = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            let scale = 1800 * self.airSpeed * (self.precise ? 0.25 : 1)
            guard let pixels = self.airFilter.sample(orientation: orientation, time: data.timestamp, scale: scale) else { return }
            self.connection.move(x: pixels.x, y: pixels.y, time: data.timestamp)
        }
    }

    private func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
