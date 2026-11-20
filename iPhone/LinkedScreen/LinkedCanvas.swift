import AVFoundation
import SwiftUI

/// Stores the visible center in display coordinates so it survives viewport resizing.
struct LinkedViewport {
    private(set) var zoom: CGFloat = 1
    private var center = CGPoint(x: 0.5, y: 0.5)

    func rect(in bounds: CGRect, display: CGSize) -> CGRect {
        let scale = min(bounds.width / display.width, bounds.height / display.height) * zoom
        let width = display.width * scale
        let height = display.height * scale
        let maxX = max(0, (width - bounds.width) / 2)
        let maxY = max(0, (height - bounds.height) / 2)
        let x = min(maxX, max(-maxX, (0.5 - center.x) * width))
        let y = min(maxY, max(-maxY, (0.5 - center.y) * height))
        return CGRect(x: bounds.midX - width / 2 + x, y: bounds.midY - height / 2 + y,
                      width: width, height: height)
    }

    mutating func scale(to requested: CGFloat, at anchor: CGPoint, in bounds: CGRect, display: CGSize) {
        let previous = rect(in: bounds, display: display)
        let next = min(5, max(1, requested))
        guard previous.width > 0, previous.height > 0, next != zoom else { return }
        if next == 1 {
            self = LinkedViewport()
            return
        }
        let ratio = next / zoom
        zoom = next
        let width = previous.width * ratio
        let height = previous.height * ratio
        let x = anchor.x + (previous.minX - anchor.x) * ratio
        let y = anchor.y + (previous.minY - anchor.y) * ratio
        setCenter(x: (bounds.midX - x) / width, y: (bounds.midY - y) / height,
                  width: width, height: height, bounds: bounds)
    }

    mutating func pan(by delta: CGPoint, in bounds: CGRect, display: CGSize) {
        let visible = rect(in: bounds, display: display)
        guard zoom > 1, visible.width > 0, visible.height > 0 else { return }
        setCenter(x: (bounds.midX - visible.minX - delta.x) / visible.width,
                  y: (bounds.midY - visible.minY - delta.y) / visible.height,
                  width: visible.width, height: visible.height, bounds: bounds)
    }

    private mutating func setCenter(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, bounds: CGRect) {
        let insetX = min(0.5, bounds.width / (2 * width))
        let insetY = min(0.5, bounds.height / (2 * height))
        center = CGPoint(x: min(1 - insetX, max(insetX, x)), y: min(1 - insetY, max(insetY, y)))
    }
}

struct LinkedCanvas: UIViewRepresentable {
    let client: LinkedClient
    enum Surface { case display, direct, trackpad }
    let surface: Surface
    let drag: Bool
    var zoomRequest: ZoomRequest? = nil
    var onPreviewTap: (() -> Void)? = nil

    struct ZoomRequest: Equatable {
        let id = UUID()
        let factor: CGFloat
    }

    func makeUIView(context: Context) -> Canvas {
        let view = Canvas()
        view.client = client
        view.surface = surface
        if surface == .trackpad {
            view.backgroundColor = .secondarySystemGroupedBackground
            view.layer.cornerRadius = 18
            view.accessibilityLabel = String(localized: "Mac trackpad")
        } else { view.layer.addSublayer(client.video) }
        return view
    }
    func updateUIView(_ view: Canvas, context: Context) {
        if view.drag != drag || view.surface != surface || !client.canPoint || !client.sceneIsActive {
            view.endDrag()
        }
        view.surface = surface
        view.drag = drag
        view.onPreviewTap = onPreviewTap
        view.zoomRequest = zoomRequest
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: Canvas, coordinator: ()) { view.endDrag() }

    final class Canvas: UIView, UIGestureRecognizerDelegate {
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
        weak var client: LinkedClient?
        var surface = Surface.display
        var drag = false
        var onPreviewTap: (() -> Void)?
        var zoomRequest: ZoomRequest?
        private var appliedZoomRequest: UUID?
        private var dragging = false
        private var rect: CGRect {
            guard let client else { return .zero }
            return client.viewport.rect(in: bounds, display: client.size)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            clipsToBounds = true
            backgroundColor = .black
            accessibilityLabel = String(localized: "Shared Mac display")
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let twice = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            twice.numberOfTapsRequired = 2
            tap.require(toFail: twice)
            let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryTap))
            secondary.numberOfTouchesRequired = 2
            tap.require(toFail: secondary)
            let right = UILongPressGestureRecognizer(target: self, action: #selector(rightClick(_:)))
            let slide = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            slide.maximumNumberOfTouches = 1
            let two = UIPanGestureRecognizer(target: self, action: #selector(twoFingers(_:)))
            two.minimumNumberOfTouches = 2; two.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let gestures = PadMotionRecognizer()
            gestures.available = { [weak self] in self?.surface == .trackpad }
            gestures.action = { [weak self] gesture in
                var message = LinkedMessage(.gesture)
                message.padGesture = gesture
                self?.client?.control(message)
            }
            gestures.scroll = { [weak self] delta, phase, _ in
                let natural = UserDefaults.standard.object(forKey: "naturalScroll") as? Bool ?? true
                var message = LinkedMessage(.scroll, x: natural ? delta.x : -delta.x, y: natural ? delta.y : -delta.y)
                message.scrollPhase = phase
                self?.client?.control(message)
            }
            addGestureRecognizer(gestures)
            installSmartTap(on: self, single: secondary, motion: gestures)
            for recognizer in [tap, twice, secondary, right, slide, two, pinch] { addGestureRecognizer(recognizer); recognizer.delegate = self }
        }
        required init?(coder: NSCoder) { nil }

        override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            if gesture is UILongPressGestureRecognizer { return surface == .direct && !drag }
            if gesture is UIPinchGestureRecognizer { return surface != .trackpad }
            if let pan = gesture as? UIPanGestureRecognizer {
                if pan.minimumNumberOfTouches == 2 { return surface != .trackpad }
                return surface != .display
            }
            if let tap = gesture as? UITapGestureRecognizer, surface == .display {
                return tap.numberOfTapsRequired == 2 || (tap.numberOfTouchesRequired == 1 && onPreviewTap != nil)
            }
            return surface != .display
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            surface != .trackpad && ((gesture is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
                || (gesture is UIPanGestureRecognizer && other is UIPinchGestureRecognizer))
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, surface != .trackpad, let client else { return }
            client.pictureInPicture?.sourceVisible(self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard surface != .trackpad, let client, bounds.width > 0, bounds.height > 0 else { return }
            if let request = zoomRequest, request.id != appliedZoomRequest {
                appliedZoomRequest = request.id
                DispatchQueue.main.async { [weak self] in
                    guard let self, window != nil, zoomRequest?.id == request.id else { return }
                    scale(to: client.viewport.zoom * request.factor, at: CGPoint(x: bounds.midX, y: bounds.midY))
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if client.video.superlayer === layer { client.video.frame = rect }
            CATransaction.commit()
        }

        private func send(_ kind: LinkedMessage.Kind, at p: CGPoint, clamp: Bool = false) {
            guard rect.width > 0, rect.height > 0, clamp || rect.contains(p) else { return }
            client?.control(.init(kind, x: min(1, max(0, (p.x-rect.minX)/rect.width)),
                                  y: min(1, max(0, (p.y-rect.minY)/rect.height))))
        }
        @objc private func tapped(_ g: UITapGestureRecognizer) {
            let twice = g.numberOfTapsRequired == 2
            if surface == .display {
                if twice, let client, rect.contains(g.location(in: self)) {
                    scale(to: client.viewport.zoom > 1 ? 1 : 2, at: g.location(in: self))
                } else if !twice {
                    onPreviewTap?()
                }
                return
            }
            if surface == .direct { send(twice ? .doubleClick : .click, at: g.location(in: self)) }
            else { client?.control(.init(twice ? .currentDouble : .currentClick)) }
        }
        @objc private func secondaryTap() {
            if surface == .trackpad { client?.control(.init(.currentRight)) }
        }
        @objc private func rightClick(_ g: UILongPressGestureRecognizer) {
            guard surface == .direct, g.state == .began, !drag else { return }
            send(.rightClick, at: g.location(in: self))
        }
        func endDrag() { if dragging { client?.releaseLinkedButton(); dragging = false } }
        @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard surface != .display else { return }
            let p = g.location(in: self), delta = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            switch g.state {
            case .began:
                if drag {
                    let start = CGPoint(x: p.x-delta.x, y: p.y-delta.y)
                    guard surface != .direct || rect.contains(start) else { return }
                    if surface == .direct { send(.dragStart, at: start) } else { client?.control(.init(.currentDown)) }
                    dragging = true
                }
                fallthrough
            case .changed:
                if surface == .direct {
                    if dragging { send(.dragMove, at: p, clamp: true) }
                } else {
                    let velocity = g.velocity(in: self)
                    let gain = 0.65 + min(2.1, hypot(velocity.x, velocity.y)/800)
                    client?.control(.init(.relative, x: delta.x*gain, y: delta.y*gain))
                }
            default: endDrag()
            }
        }
        @objc private func twoFingers(_ g: UIPanGestureRecognizer) {
            let delta = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            guard surface != .trackpad, let client else { return }
            client.updateViewport { $0.pan(by: delta, in: bounds, display: client.size) }
            setNeedsLayout()
        }

        @objc private func pinch(_ g: UIPinchGestureRecognizer) {
            guard surface != .trackpad, let client else { return }
            scale(to: client.viewport.zoom * g.scale, at: g.location(in: self))
            g.scale = 1
        }

        private func scale(to zoom: CGFloat, at point: CGPoint) {
            guard let client else { return }
            client.updateViewport { $0.scale(to: zoom, at: point, in: bounds, display: client.size) }
            setNeedsLayout()
        }
    }
}
