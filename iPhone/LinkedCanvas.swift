import AVFoundation
import SwiftUI

struct LinkedCanvas: UIViewRepresentable {
    let client: LinkedClient
    let direct: Bool
    let drag: Bool
    let reset: Int

    func makeUIView(context: Context) -> Canvas {
        let view = Canvas()
        view.client = client
        view.layer.addSublayer(client.video)
        return view
    }
    func updateUIView(_ view: Canvas, context: Context) {
        if view.drag != drag || view.direct != direct {
            view.endDrag()
        }
        view.direct = direct
        view.drag = drag
        if view.reset != reset { view.zoom = 1; view.offset = .zero; view.reset = reset }
        view.setNeedsLayout()
    }

    final class Canvas: UIView, UIGestureRecognizerDelegate {
        weak var client: LinkedClient?
        var direct = true, drag = false, reset = 0
        var zoom = CGFloat(1), offset = CGPoint.zero
        private var dragging = false
        private var rect = CGRect.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            backgroundColor = .black
            accessibilityLabel = "Shared Mac display"
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let twice = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            twice.numberOfTapsRequired = 2
            tap.require(toFail: twice)
            let right = UILongPressGestureRecognizer(target: self, action: #selector(rightClick(_:)))
            let slide = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            slide.maximumNumberOfTouches = 1
            let two = UIPanGestureRecognizer(target: self, action: #selector(twoFingers(_:)))
            two.minimumNumberOfTouches = 2; two.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            for recognizer in [tap, twice, right, slide, two, pinch] { addGestureRecognizer(recognizer); recognizer.delegate = self }
        }
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let client, bounds.width > 0, bounds.height > 0 else { return }
            let factor = min(bounds.width / client.size.width, bounds.height / client.size.height) * zoom
            let w = client.size.width * factor, h = client.size.height * factor
            let maxX = max(0, (w-bounds.width)/2), maxY = max(0, (h-bounds.height)/2)
            offset.x = min(maxX, max(-maxX, offset.x)); offset.y = min(maxY, max(-maxY, offset.y))
            rect = CGRect(x: bounds.midX-w/2+offset.x, y: bounds.midY-h/2+offset.y, width: w, height: h)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            client.video.frame = rect
            CATransaction.commit()
        }

        private func send(_ kind: LinkedMessage.Kind, at p: CGPoint, clamp: Bool = false) {
            guard rect.width > 0, rect.height > 0, clamp || rect.contains(p) else { return }
            client?.control(.init(kind, x: min(1, max(0, (p.x-rect.minX)/rect.width)),
                                  y: min(1, max(0, (p.y-rect.minY)/rect.height))))
        }
        @objc private func tapped(_ g: UITapGestureRecognizer) {
            let twice = g.numberOfTapsRequired == 2
            if direct { send(twice ? .doubleClick : .click, at: g.location(in: self)) }
            else { client?.control(.init(twice ? .currentDouble : .currentClick)) }
        }
        @objc private func rightClick(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, !drag else { return }
            if direct { send(.rightClick, at: g.location(in: self)) }
            else { client?.control(.init(.currentRight)) }
        }
        func endDrag() { if dragging { client?.control(.init(.dragEnd)); dragging = false } }
        @objc private func pan(_ g: UIPanGestureRecognizer) {
            let p = g.location(in: self), delta = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            switch g.state {
            case .began:
                if drag {
                    let start = CGPoint(x: p.x-delta.x, y: p.y-delta.y)
                    guard !direct || rect.contains(start) else { return }
                    if direct { send(.dragStart, at: start) } else { client?.control(.init(.currentDown)) }
                    dragging = true
                }
                fallthrough
            case .changed:
                if direct {
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
            if direct { offset.x += delta.x; offset.y += delta.y; setNeedsLayout() }
            else { client?.control(.init(.scroll, x: delta.x, y: delta.y)) }
        }
        @objc private func pinch(_ g: UIPinchGestureRecognizer) {
            guard direct else { return }
            let old = zoom
            zoom = min(5, max(1, zoom * g.scale))
            let p = g.location(in: self), ratio = zoom / old
            offset.x = (offset.x + bounds.midX - p.x) * ratio + p.x - bounds.midX
            offset.y = (offset.y + bounds.midY - p.y) * ratio + p.y - bounds.midY
            g.scale = 1
            setNeedsLayout()
        }
    }
}
