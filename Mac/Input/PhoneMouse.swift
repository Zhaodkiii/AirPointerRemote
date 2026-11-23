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
            scroll(x: command.x, y: command.y, phase: command.phase)
        case .padGesture:
            if let gesture = PhoneProtocol.PadGesture(rawValue: command.phase) { perform(gesture) }
        case .center:
            reset()
            let screen = Displays.bounds(containing: location)
            post(.mouseMoved, at: CGPoint(x: screen.midX, y: screen.midY))
            history.removeAll()
        case .stop, .pause, .disconnect: reset()
        default: break
        }
    }

    func scroll(x: Double, y: Double, phase: UInt8, at point: CGPoint? = nil) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(max(-10000, min(10000, y))),
            wheel2: Int32(max(-10000, min(10000, x))), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        if let point { event.location = point }
        emit(event)
    }

    func perform(_ gesture: PhoneProtocol.PadGesture) {
        guard !held else { return }
        let key: CGKeyCode
        let flags: CGEventFlags
        switch gesture {
        case .previousSpace: switchSpace(arrow: 123); return
        case .nextSpace: switchSpace(arrow: 124); return
        case .notifications: (key, flags) = (45, .maskSecondaryFn)
        case .missionControl:
            if openSystemApp("Mission Control") { return }
            (key, flags) = (126, .maskControl)
        case .appWindows: (key, flags) = (125, .maskControl)
        case .apps:
            if openSystemApp("Apps") || openSystemApp("Launchpad") { return }
            (key, flags) = (0, [.maskShift, .maskSecondaryFn])
        case .desktop: (key, flags) = (4, .maskSecondaryFn)
        default:
            performMenuGesture(gesture)
            return
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
            event.flags = flags
            emit(event)
        }
    }

    private func switchSpace(arrow: CGKeyCode) {
        // Physical arrow keys carry both secondary-Fn and numeric-pad flags.
        // Post the complete chord so the system hotkey dispatcher sees Control.
        let source = CGEventSource(stateID: .privateState)
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        guard let controlDown = CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: false) else { return }
        controlDown.type = .flagsChanged
        controlDown.flags = .maskControl
        down.flags = arrowFlags
        up.flags = arrowFlags
        controlUp.type = .flagsChanged
        controlUp.flags = []
        [controlDown, down, up, controlUp].forEach(emit)
    }

    var openSystemApp: (String) -> Bool = { name in
        let url = URL(fileURLWithPath: "/System/Applications").appendingPathComponent(name + ".app")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // Use enabled commands from the foreground app. A rotation in a browser,
    // for example, must never accidentally invoke its Reload shortcut.
    private func performMenuGesture(_ gesture: PhoneProtocol.PadGesture) {
        let titles: Set<String>
        switch gesture {
        case .zoomIn: titles = ["Zoom In", "放大"]
        case .zoomOut: titles = ["Zoom Out", "缩小", "縮小"]
        case .fit: titles = ["Zoom to Fit", "Fit to Window", "Actual Size", "Zoom to Actual Size", "适合窗口", "符合視窗大小", "实际大小", "實際大小"]
        case .rotateLeft: titles = ["Rotate Left", "向左旋转", "向左旋轉"]
        case .rotateRight: titles = ["Rotate Right", "向右旋转", "向右旋轉"]
        case .back: titles = ["Back", "Go Back", "后退", "返回", "上一页", "上一頁"]
        case .forward: titles = ["Forward", "Go Forward", "前进", "前進", "下一页", "下一頁"]
        default: return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        func attribute(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(item, key as CFString, &value)
            return value
        }
        guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
        func children(_ item: AXUIElement) -> [AXUIElement] {
            attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        for heading in children(bar as! AXUIElement) {
            for menu in children(heading) {
                for item in children(menu) {
                    guard let name = attribute(item, kAXTitleAttribute) as? String, titles.contains(name) else { continue }
                    if attribute(item, kAXEnabledAttribute) as? Bool == true {
                        AXUIElementPerformAction(item, kAXPressAction as CFString)
                        return
                    }
                }
            }
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
