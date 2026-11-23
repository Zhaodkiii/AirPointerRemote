import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct TrackpadView: UIViewRepresentable {
    let controller: RemoteController
    var enabled: Bool

    func makeUIView(context: Context) -> PadView { PadView(controller: controller) }
    func updateUIView(_ view: PadView, context: Context) { view.isUserInteractionEnabled = enabled }
}

final class PadView: UIView, UIGestureRecognizerDelegate {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    private let controller: RemoteController
    private var dragRecognizer: UILongPressGestureRecognizer!
    private var dragPoint = CGPoint.zero
    private var dragTime: TimeInterval = 0

    init(controller: RemoteController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityLabel = String(localized: "Mouse Trackpad")
        accessibilityHint = String(localized: "Slide one finger to move. Tap to click. Scroll or right-click with two fingers.")
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = TimestampedTap(target: self, action: #selector(tap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let right = UITapGestureRecognizer(target: self, action: #selector(rightTap(_:)))
        right.numberOfTouchesRequired = 2
        dragRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
        dragRecognizer.numberOfTapsRequired = 1
        dragRecognizer.minimumPressDuration = 0.15
        dragRecognizer.allowableMovement = 18
        pan.delegate = self
        dragRecognizer.delegate = self
        tap.require(toFail: doubleTap)
        tap.require(toFail: right)
        doubleTap.require(toFail: dragRecognizer)
        let gestures = PadMotionRecognizer()
        gestures.action = { [weak controller] gesture in
            guard let controller, controller.canControl else { return }
            controller.connection.send(.init(.padGesture, phase: gesture.rawValue))
        }
        gestures.scroll = { [weak controller] delta, phase, velocity in
            switch phase {
            case 1: controller?.beginScroll()
            case 4: controller?.endScroll(velocity: velocity)
            default: controller?.scroll(delta, phase: phase)
            }
        }
        installSmartTap(on: self, single: right, motion: gestures)
        for recognizer in [pan, tap, doubleTap, right, gestures, dragRecognizer] {
            addGestureRecognizer(recognizer!)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === dragRecognizer || other === dragRecognizer) &&
        (gestureRecognizer is UIPanGestureRecognizer || other is UIPanGestureRecognizer)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { controller.beginTouchMovement() }
        guard dragRecognizer.state != .began, dragRecognizer.state != .changed else { return }
        if pan.state == .changed {
            controller.touchMoved(pan.translation(in: self), velocity: pan.velocity(in: self))
            pan.setTranslation(.zero, in: self)
        }
    }

    @objc private func tap(_ tap: TimestampedTap) { controller.click(touchTime: tap.touchTime) }
    @objc private func doubleTap(_ tap: UITapGestureRecognizer) { controller.click(double: true) }
    @objc private func rightTap(_ tap: UITapGestureRecognizer) { controller.click(right: true) }

    @objc private func drag(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: self)
        switch hold.state {
        case .began:
            dragPoint = point
            dragTime = ProcessInfo.processInfo.systemUptime
            controller.beginTouchMovement()
            controller.left(true, source: "trackpad")
        case .changed:
            let delta = CGPoint(x: point.x - dragPoint.x, y: point.y - dragPoint.y)
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = max(now - dragTime, 0.001)
            controller.touchMoved(delta, velocity: CGPoint(x: delta.x / elapsed, y: delta.y / elapsed))
            dragPoint = point
            dragTime = now
        case .ended, .cancelled, .failed: controller.left(false, source: "trackpad")
        default: break
        }
    }
}

private final class TimestampedTap: UITapGestureRecognizer {
    private(set) var touchTime: TimeInterval?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touchTime == nil { touchTime = touches.first?.timestamp }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        touchTime = nil
    }
}

/// Touch-down/up callbacks work while another finger moves on the trackpad.
struct HoldControl: UIViewRepresentable {
    let title: String
    var enabled = true
    var cancelled: (() -> Void)? = nil
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> HoldView { HoldView() }
    func updateUIView(_ view: HoldView, context: Context) {
        view.setTitle(title, for: .normal)
        view.changed = changed
        view.cancelled = cancelled
        view.isEnabled = enabled
        view.alpha = enabled ? 1 : 0.4
    }
}

final class HoldView: UIButton {
    var changed: ((Bool) -> Void)?
    var cancelled: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemGroupedBackground
        layer.cornerRadius = 18
        titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        setTitleColor(.label, for: .normal)
        isExclusiveTouch = false
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        changed?(true)
        backgroundColor = .systemBlue.withAlphaComponent(0.3)
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        release(cancelled: touch.map { !bounds.contains($0.location(in: self)) } ?? true)
    }
    override func cancelTracking(with event: UIEvent?) { release(cancelled: true) }
    private func release(cancelled didCancel: Bool) {
        if didCancel, let cancelled { cancelled() } else { changed?(false) }
        backgroundColor = .secondarySystemGroupedBackground
    }
}

private func padOption(_ name: String, default fallback: Bool = true) -> Bool {
    UserDefaults.standard.object(forKey: "pad." + name) as? Bool ?? fallback
}

func installSmartTap(on view: UIView, single: UITapGestureRecognizer, motion: PadMotionRecognizer) {
    let tap = UITapGestureRecognizer(target: motion, action: #selector(PadMotionRecognizer.fit))
    tap.numberOfTouchesRequired = 2
    tap.numberOfTapsRequired = 2
    tap.delegate = motion
    single.require(toFail: tap)
    view.addGestureRecognizer(tap)
}

/// Rebase when another finger lands; dispatch at most one system action per chord.
final class PadMotionRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var usesDesktopGestures: () -> Bool = { false }
    var desktopPinch: ((CGFloat, CGPoint) -> Void)?
    var gestureOrigin: CGPoint { origin }
    var available: () -> Bool = { true }
    var action: ((PhoneProtocol.PadGesture) -> Void)?
    var scroll: ((CGPoint, UInt8, CGPoint) -> Void)?
    private enum Mode { case pending, scroll, scale, rotation, fired }
    private var mode = Mode.pending
    private var fingers: [UITouch] = []
    private var origin = CGPoint.zero, last = CGPoint.zero, velocity = CGPoint.zero
    private var radius: CGFloat = 0, angle: CGFloat = 0
    private var timestamp: TimeInterval = 0
    private let gestureFeedback = UISelectionFeedbackGenerator()
    private var lastLanding: TimeInterval = 0

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        available() && !usesDesktopGestures() && padOption("fit")
    }
    @objc func fit() { if available() { action?(.fit) } }

    private var center: CGPoint {
        let sum = fingers.reduce(CGPoint.zero) { sum, touch in
            let p = touch.location(in: view)
            return CGPoint(x: sum.x + p.x, y: sum.y + p.y)
        }
        return CGPoint(x: sum.x / CGFloat(fingers.count), y: sum.y / CGFloat(fingers.count))
    }
    private func geometry() -> (CGFloat, CGFloat) {
        let c = center
        let p = fingers[0].location(in: view)
        let distance = fingers.reduce(CGFloat.zero) { sum, touch in
            let q = touch.location(in: view)
            return sum + hypot(q.x - c.x, q.y - c.y)
        } / CGFloat(fingers.count)
        return (distance, atan2(p.y - c.y, p.x - c.x))
    }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
        // The first finger can start a pointer pan before the others arrive.
        if other.view === view, let pan = other as? UIPanGestureRecognizer,
           pan.maximumNumberOfTouches == 1 { return false }
        return super.canBePrevented(by: other)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard available(), mode != .fired, fingers.count + touches.count <= 4 else {
            if mode == .scroll { scroll?(.zero, 8, .zero) }
            state = state == .possible ? .failed : .cancelled
            return
        }
        if mode == .scroll { scroll?(.zero, 8, .zero) }
        mode = .pending
        velocity = .zero
        lastLanding = event.timestamp
        fingers.append(contentsOf: touches)
        if fingers.count >= 3 { gestureFeedback.prepare() }
        origin = center
        last = origin
        (radius, angle) = geometry()
        timestamp = event.timestamp
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        evaluate(at: event.timestamp, lifting: false)
    }

    private func evaluate(at time: TimeInterval, lifting: Bool) {
        guard fingers.count >= 2, available(), mode != .fired else { return }
        // Give staggered contacts time to assemble before scrolling or switching Spaces.
        // Evaluate again at lift so a quick swipe still counts.
        if mode == .pending && fingers.count == 2 && !lifting && time - lastLanding < 0.035 { return }
        let p = center, dx = p.x - origin.x, dy = p.y - origin.y
        let (size, direction) = geometry()
        let scale = size / max(1, radius)
        let rotation = atan2(sin(direction - angle), cos(direction - angle))
        if usesDesktopGestures() {
            guard fingers.count == 2 else { return }
            if mode == .pending {
                let separation = abs(size - radius)
                let travel = hypot(dx, dy)
                if separation > 3 && separation > travel * 0.6 { mode = .scale }
                else if travel > 7 { mode = .scroll }
                else { return }
                state = .began
                if mode == .scroll { scroll?(.zero, 1, .zero) }
            }
            if mode == .scale {
                desktopPinch?(scale, p)
                radius = size
            } else if mode == .scroll {
                scroll?(CGPoint(x: p.x - last.x, y: p.y - last.y), 2, .zero)
            }
            last = p
            return
        }
        if mode == .pending {
            if fingers.count == 4 {
                if abs(log(max(0.01, scale))) > 0.135 && abs(size - radius) >= 5 && padOption("four") {
                    fire(scale > 1 ? .desktop : .apps)
                }
                return
            }
            if fingers.count == 3 {
                let travel = max(abs(dx), abs(dy))
                let cross = min(abs(dx), abs(dy))
                let elapsed = max(0.001, time - lastLanding)
                let threshold: CGFloat = travel / elapsed >= 420 ? 16 : 24
                if travel >= threshold && travel > cross * 1.3 && padOption("spaces") {
                    fire(abs(dx) > abs(dy) ? (dx < 0 ? .nextSpace : .previousSpace) : (dy < 0 ? .missionControl : .appWindows))
                }
                return
            }
            if abs(rotation) > 0.22 && padOption("rotate") { mode = .rotation }
            else if abs(log(max(0.01, scale))) > 0.11 && padOption("zoom") { mode = .scale }
            else if hypot(dx, dy) > 8 {
                let horizontal = abs(dx) > abs(dy) * 2.2
                let edge = origin.x > (view?.bounds.width ?? 0) - 46 && dx < 0 && padOption("notifications")
                if horizontal && (edge || padOption("pages", default: false)) {
                    if abs(dx) >= 54 { fire(edge ? .notifications : (dx > 0 ? .back : .forward)) }
                    return
                }
                mode = .scroll
            } else { return }
            if state == .possible { state = .began }
            if mode == .scroll { scroll?(.zero, 1, .zero) }
        }
        if mode == .scale && (scale > 1.22 || scale < 1/1.22) {
            action?(scale > 1 ? .zoomIn : .zoomOut)
            radius = size
        } else if mode == .rotation && abs(rotation) > 0.56 {
            fire(rotation > 0 ? .rotateRight : .rotateLeft)
        } else if mode == .scroll {
            let delta = CGPoint(x: p.x-last.x, y: p.y-last.y)
            let dt = max(0.005, time - timestamp)
            velocity = CGPoint(x: delta.x/dt, y: delta.y/dt)
            last = p
            timestamp = time
            scroll?(delta, 2, velocity)
        }
    }
    private func fire(_ gesture: PhoneProtocol.PadGesture) {
        if state == .possible { state = .began }
        mode = .fired
        action?(gesture)
        if fingers.count >= 3 { gestureFeedback.selectionChanged() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if mode == .pending && fingers.count >= 2 { evaluate(at: event.timestamp, lifting: true) }
        if mode == .scroll { scroll?(.zero, 4, event.timestamp - timestamp < 0.09 ? velocity : .zero) }
        state = state == .possible ? .failed : .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if mode == .scroll { scroll?(.zero, 8, .zero) }
        state = state == .possible ? .failed : .cancelled
    }
    override func reset() {
        super.reset()
        fingers.removeAll()
        velocity = .zero
        mode = .pending
    }
}
