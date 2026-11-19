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
    private let controller: RemoteController
    private var dragRecognizer: UILongPressGestureRecognizer!
    private var dragPoint = CGPoint.zero
    private var dragTime: TimeInterval = 0

    init(controller: RemoteController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityLabel = "Mouse Trackpad"
        accessibilityHint = "Slide one finger to move. Tap to click. Scroll or right-click with two fingers."
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
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
        for recognizer in [pan, scroll, tap, doubleTap, right, dragRecognizer] {
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

    @objc private func scroll(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: controller.beginScroll(); pan.setTranslation(.zero, in: self)
        case .changed:
            controller.scroll(pan.translation(in: self), phase: 2)
            pan.setTranslation(.zero, in: self)
        case .ended: controller.endScroll(velocity: pan.velocity(in: self))
        case .cancelled, .failed: controller.scroll(.zero, phase: 8)
        default: break
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
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> HoldView { HoldView() }
    func updateUIView(_ view: HoldView, context: Context) {
        view.setTitle(title, for: .normal)
        view.changed = changed
        view.isEnabled = enabled
        view.alpha = enabled ? 1 : 0.4
    }
}

final class HoldView: UIButton {
    var changed: ((Bool) -> Void)?
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
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { release() }
    override func cancelTracking(with event: UIEvent?) { release() }
    private func release() {
        changed?(false)
        backgroundColor = .secondarySystemGroupedBackground
    }
}
