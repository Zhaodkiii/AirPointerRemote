import AppKit

/// System mouse events for authenticated phone commands. Owned by the BLE queue.
final class PhoneMouse {
    var emit: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    private(set) var held = false
    private var lastClickTime = 0.0
    private var lastClickPoint = CGPoint.zero
    private var clickCount: Int64 = 0
    private var history: [(Double, CGPoint)] = []
    private var clockOffset: Double?

    var readLocation: () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    var location: CGPoint { readLocation() }

    private var pointerPosition: CGPoint?
    private var target: CGPoint?
    private var segmentStart = CGPoint.zero
    private var segmentTime: TimeInterval = 0
    private var lastMoveTime: TimeInterval?
    private let smoothingDuration: TimeInterval = 0.012

    func handle(_ command: PhoneProtocol.Command, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        clockOffset = min(clockOffset ?? .infinity, now - command.time)
        switch command.action {
        case .move:
            if lastMoveTime.map({ now - $0 > 0.1 }) ?? true {
                pointerPosition = location
                target = nil
            } else {
                render(at: now)
            }
            lastMoveTime = now
            let current = pointerPosition ?? location
            let base = target ?? current
            target = Displays.clamp(CGPoint(x: base.x + max(-2000, min(2000, command.x)),
                                             y: base.y + max(-2000, min(2000, command.y))))
            segmentStart = current
            segmentTime = now
        case .leftDown:
            guard !held else { return }
            flushMovement(at: now)
            let moment = command.time + (clockOffset ?? 0)
            let point = command.phase == 1 ? history.last(where: { $0.0 <= moment })?.1 ?? currentPosition(at: now) : currentPosition(at: now)
            let isDouble = now - lastClickTime < NSEvent.doubleClickInterval && hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 5
            clickCount = isDouble ? min(clickCount + 1, 3) : 1
            held = true
            pointerPosition = point
            post(.leftMouseDown, at: point, count: clickCount)
            lastClickPoint = point
            lastClickTime = now
        case .leftUp:
            flushMovement(at: now)
            release(at: currentPosition(at: now))
        case .rightClick:
            flushMovement(at: now)
            let point = currentPosition(at: now)
            release(at: point)
            post(.rightMouseDown, at: point, button: .right)
            post(.rightMouseUp, at: point, button: .right)
        case .doubleClick:
            flushMovement(at: now)
            let point = currentPosition(at: now)
            release(at: point)
            for count: Int64 in [1, 2] {
                post(.leftMouseDown, at: point, count: count)
                post(.leftMouseUp, at: point, count: count)
            }
            lastClickTime = 0
        case .scroll:
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(max(-10000, min(10000, command.y))),
                wheel2: Int32(max(-10000, min(10000, command.x))), wheel3: 0) else { return }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(command.phase))
            emit(event)
        case .center:
            reset()
            let screen = Displays.bounds(containing: location)
            post(.mouseMoved, at: CGPoint(x: screen.midX, y: screen.midY))
            history.removeAll()
        case .stop, .pause, .disconnect: reset()
        default: break
        }
    }

    private func currentPosition(at now: TimeInterval) -> CGPoint {
        guard let lastMoveTime, now - lastMoveTime < 0.1 else { return location }
        return pointerPosition ?? location
    }

    func render(at now: TimeInterval) {
        guard let target else { return }
        let progress = min(max((now - segmentTime) / smoothingDuration, 0), 1)
        let point = CGPoint(x: segmentStart.x + (target.x - segmentStart.x) * progress,
                            y: segmentStart.y + (target.y - segmentStart.y) * progress)
        movePointer(to: Displays.clamp(point), at: now)
        if progress >= 1 { self.target = nil }
    }

    private func flushMovement(at now: TimeInterval) {
        guard let target else { return }
        self.target = nil
        movePointer(to: target, at: now)
    }

    private func movePointer(to point: CGPoint, at now: TimeInterval) {
        guard pointerPosition != point else { return }
        pointerPosition = point
        post(held ? .leftMouseDragged : .mouseMoved, at: point)
        history.append((now, point))
        history.removeAll { now - $0.0 > 0.3 }
    }

    func position(at point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        target = nil
        lastMoveTime = now
        pointerPosition = nil
        movePointer(to: point, at: now)
    }

    private func release(at point: CGPoint) {
        guard held else { return }
        held = false
        post(.leftMouseUp, at: point, count: clickCount)
    }

    func reset() {
        release(at: location)
        target = nil
        pointerPosition = nil
        lastMoveTime = nil
        history.removeAll()
        clockOffset = nil
        lastClickTime = 0
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, count: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: count)
        emit(event)
    }
}
