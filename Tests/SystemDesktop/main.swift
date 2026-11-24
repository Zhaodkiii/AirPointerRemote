import AppKit
import CoreVideo
import SwiftUI
import WebKit
@MainActor func test() {
    _ = NSApplication.shared
    let session = DesktopSession()
    let args = CommandLine.arguments
    let account = args[2] == "account"
    guard let dest = DesktopComputer.parse("127.0.0.1:" + args[1]) else { exit(1) }
    var connected = false
    session.start(dest, username: "test", password: "example", account: account) { connected = true }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "AirPointer local framebuffer check"
    window.contentView = session.web
    window.orderBack(nil)
    let end = Date().addingTimeInterval(12)
    while !connected && Date() < end && session.web != nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard connected else { print(session.status); exit(1) }
    // The fixture sends a 2 × 2 red rectangle. A successful handshake alone
    // would miss regressions in framebuffer delivery and canvas rendering.
    var redPixel = false
    let paintDeadline = Date().addingTimeInterval(3)
    while !redPixel && Date() < paintDeadline {
        session.web?.evaluateJavaScript("Array.from(document.querySelector('canvas').getContext('2d').getImageData(0,0,1,1).data)") { value, _ in
            if let rgba = value as? [Int], rgba == [255, 0, 0, 255] { redPixel = true }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard redPixel else { print("framebuffer pixel mismatch"); exit(1) }
    // The PiP player must receive actual framebuffer pixels, including on a static desktop.
    func playerShows(_ channel: Int) -> Bool {
        var matches = false
        let deadline = Date().addingTimeInterval(4)
        while !matches && Date() < deadline {
            if let buffer = session.mirrorVideo.lastFrame {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                if let pixel = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                    matches = pixel[2 - channel] > 200 && pixel[1 + channel] < 40 && pixel[0] < 40
                }
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return matches
    }
    guard playerShows(0) else { print("PiP first frame mismatch"); exit(1) }
    session.send(key: 67)
    guard playerShows(1) else { print("PiP did not receive the next framebuffer update"); exit(1) }
    guard session.resolution == "2 × 2" else { print("resolution metadata mismatch"); exit(1) }
    var viewportPassed = false
    session.web?.evaluateJavaScript("""
        (() => {
            const root = document.querySelector('main');
            const canvas = document.querySelector('canvas');
            const base = canvas.getBoundingClientRect();
            adjustViewport(0.5, 0.5, 0.5, 0.5, 2);
            const zoomed = canvas.getBoundingClientRect();
            resetViewport();
            const reset = canvas.getBoundingClientRect();
            const u = (reset.left + 1) / root.clientWidth;
            const v = (reset.bottom - 1) / root.clientHeight;
            directTouch('click', u, v);
            directTouch('right', u, v);
            directTouch('down', u, v);
            directTouch('move', 2, v);
            endScroll();
            startScroll((reset.left+1)/root.clientWidth, (reset.top+1)/root.clientHeight);

            return zoomed.width > base.width && zoomed.left < base.left &&
                reset.width === base.width && reset.left === base.left;
        })()
        """) { value, _ in viewportPassed = value as? Bool == true }
    let zoomDeadline = Date().addingTimeInterval(3)
    while !viewportPassed && Date() < zoomDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard viewportPassed else { print("WebKit pinch and viewport reset failed"); exit(1) }
    for spacing: CGFloat in [14, 18] {
        var wheel = MirrorWheelMotion(spacing: spacing)
        let atPointer = spacing == 18
        assert(wheel.ticks(for: .zero) == .zero)
        let first = wheel.ticks(for: CGPoint(x: 0, y: -1))
        assert(first == CGPoint(x: 0, y: -1))
        session.scroll(first, atPointer: atPointer)
        for _ in 1..<Int(spacing) {
            assert(wheel.ticks(for: CGPoint(x: 0, y: -1)) == .zero)
        }
        let second = wheel.ticks(for: CGPoint(x: 0, y: -1))
        assert(second == first)
        session.scroll(second, atPointer: atPointer)
        session.endScroll()
    }
    session.configure(scale: "fill", observing: true, quality: 3)
    session.send(key: 66)
    session.configure(scale: "fit", observing: false, quality: 6)
    session.pad("move", -1000, -1000)
    session.pad("press", 1)
    session.pad("move", 1000, 1000)
    session.pad("release", 1)
    session.pad("pulse", 4)
    session.pad("pulse", 8)
    var probes = [Double]()
    session.onMirrorClick = { _, token in probes.append(token) }
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
    session.touch("click", at: CGPoint(x: 0.5, y: 0.5))
    settle()
    guard probes.count == 1, probes.last == session.focusRequest else { print("missing focus probe"); exit(1) }
    session.cancelFocusRequest() // User dismissed the keyboard.
    session.touch("click", at: CGPoint(x: 0.5, y: 0.5))
    settle()
    guard probes.count == 2, probes[0] != probes[1] else { print("repeat click did not rearm"); exit(1) }
    session.startScroll(CGPoint(x: 0.5, y: 0.5))
    session.endScroll()
    session.pad("pulse", 4)
    settle()
    guard probes.count == 2, session.focusRequest == 0 else { print("non-click focus probe"); exit(1) }
    session.pad("pulse", 1)
    settle()
    guard probes.count == 3 else { print("missing trackpad focus probe"); exit(1) }
    session.configure(scale: "fill", observing: false, quality: 6, adaptive: true)
    session.send(text: "A")
    session.send(key: 0xff09, modifiers: [0xffeb])
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    session.stop()
    print("connected and sent input")
}
MainActor.assumeIsolated { test() }
