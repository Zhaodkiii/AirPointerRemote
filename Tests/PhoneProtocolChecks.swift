import AppKit
import CryptoKit
import simd

@main
struct PhoneProtocolChecks {
    static func main() throws {
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let client = PhoneProtocol.Hello(name: "Phone", publicKey: clientKey.publicKey.rawRepresentation, nonce: PhoneProtocol.nonce())
        let server = PhoneProtocol.Hello(name: "Mac", publicKey: serverKey.publicKey.rawRepresentation, nonce: PhoneProtocol.nonce())
        let a = try PhoneProtocol.session(privateKey: clientKey, client: client, server: server, serverSide: false)
        let b = try PhoneProtocol.session(privateKey: serverKey, client: client, server: server, serverSide: true)
        precondition(PhoneProtocol.code(a) == PhoneProtocol.code(b))
        let command = PhoneProtocol.Command(.move, x: -12.25, y: 30.5, time: 1234)
        let encrypted = try PhoneProtocol.seal(command.data, key: a, sequence: 1, direction: 2)
        let opened = try PhoneProtocol.open(encrypted, key: b, after: 0, direction: 2)
        let decoded = PhoneProtocol.Command(data: opened.1)!
        precondition(decoded.x == command.x && decoded.y == command.y && decoded.time == command.time)
        precondition((try? PhoneProtocol.open(encrypted, key: b, after: 1, direction: 2)) == nil, "Replay must fail")
        precondition((try? PhoneProtocol.open(encrypted, key: b, after: 0, direction: 3)) == nil, "Reflection must fail")
        var tampered = encrypted
        tampered[tampered.count - 1] ^= 1
        precondition((try? PhoneProtocol.open(tampered, key: b, after: 0, direction: 2)) == nil, "Tamper must fail")
        let renewed = PhoneProtocol.Hello(name: "Mac", publicKey: server.publicKey, nonce: PhoneProtocol.nonce())
        let renewedKey = try PhoneProtocol.session(privateKey: serverKey, client: client, server: renewed, serverSide: true)
        precondition((try? PhoneProtocol.open(encrypted, key: renewedKey, after: 0, direction: 2)) == nil, "Old session must fail")
        for mtu in [20, 64, 185, 512] {
            var assembler = PhoneAssembler()
            let payload = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0) })
            let fragments = PhoneProtocol.fragments(payload, mtu: mtu, id: 65535)
            precondition(fragments.allSatisfy { $0.count <= mtu })
            var result: Data?
            for fragment in fragments { result = assembler.append(fragment) }
            precondition(result == payload)
        }
        var assembler = PhoneAssembler()
        let fragments = PhoneProtocol.fragments(encrypted, mtu: 20, id: 2)
        _ = assembler.append(fragments[0])
        precondition(assembler.append(fragments[2]) == nil, "Out of order fragments must fail")
        precondition(PhoneProtocol.Command(data: Data(repeating: 0, count: 3)) == nil)
        precondition(PhoneProtocol.Command(data: PhoneProtocol.Command(.move, x: .nan).data) == nil)

        let mouse = PhoneMouse()
        var events: [CGEvent] = []
        let origin = Displays.bounds(containing: mouse.location)
        let start = CGPoint(x: origin.midX, y: origin.midY)
        var cursor = start
        mouse.readLocation = { cursor }
        mouse.emit = { event in events.append(event); if event.type != .scrollWheel { cursor = event.location } }
        mouse.handle(.init(.leftDown))
        mouse.handle(.init(.leftDown))
        precondition(events.count == 1 && mouse.held, "Duplicate down must be idempotent")
        mouse.handle(.init(.move, x: 10, y: 20), at: 10)
        mouse.render(at: 10.006)
        precondition(events.last?.type == .leftMouseDragged)
        precondition(abs(cursor.x - start.x - 5) < 1)
        mouse.handle(.init(.move, x: 9, y: 0), at: 10.009)
        mouse.handle(.init(.leftUp), at: 10.01)
        precondition(events.last?.type == .leftMouseUp)
        precondition(abs(cursor.x - start.x - 19) < 1 && abs(cursor.y - start.y - 20) < 1,
                     "All movement must land before button release")
        mouse.handle(.init(.leftDown), at: 10.02)
        mouse.handle(.init(.heartbeat))
        precondition(mouse.held, "Heartbeat must retain a stationary drag")
        mouse.reset()
        precondition(!mouse.held && events.last?.type == .leftMouseUp)
        let count = events.count
        mouse.reset()
        precondition(events.count == count, "Repeated reset must not emit another up")
        events.removeAll()
        mouse.handle(.init(.doubleClick))
        precondition(events.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        precondition(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2])
        events.removeAll()
        mouse.handle(.init(.rightClick))
        precondition(events.map(\.type) == [.rightMouseDown, .rightMouseUp])
        mouse.handle(.init(.scroll, x: 12, y: -25, phase: 2))
        precondition(events.last?.type == .scrollWheel)
        precondition(events.last?.getIntegerValueField(.scrollWheelEventScrollPhase) == 2)
        for point in [CGPoint(x: -1e8, y: -1e8), CGPoint(x: 1e8, y: 1e8)] {
            let clamped = Displays.clamp(point)
            precondition(Displays.bounds(containing: clamped).contains(clamped))
        }
        var air = AirMotionFilter()
        let identity = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
        precondition(air.sample(orientation: identity, time: 0, scale: 1800) == nil)
        let still = air.sample(orientation: identity, time: 0.01, scale: 1800)!
        precondition(simd_length(still) == 0)
        let turn = air.sample(orientation: simd_quatd(angle: -0.02, axis: SIMD3(0, 0, 1)), time: 0.02, scale: 1800)!
        precondition(turn.x > 0 && abs(turn.y) < 0.001, "Right turn must move right")
        let settled = air.sample(orientation: simd_quatd(angle: -0.02, axis: SIMD3(0, 0, 1)), time: 0.03, scale: 1800)
        precondition(settled == .zero, "Stopping the phone must clear the filter tail")
        air.reset()
        precondition(air.sample(orientation: identity, time: 1, scale: 1800) == nil, "Clutch must not jump")
        let tilt = air.sample(orientation: simd_quatd(angle: 0.02, axis: SIMD3(1, 0, 0)), time: 1.01, scale: 1800)!
        precondition(tilt.y < 0, "Tilt up must move up")
        let vertical = simd_quatd(angle: Double.pi / 2, axis: SIMD3(1, 0, 0))
        precondition(air.sample(orientation: vertical, time: 1.02, scale: 1800) == nil)
        precondition(air.sample(orientation: identity, time: 1.03, scale: 1800) == nil, "Recovering vertical pose must not jump")
        air.reset()
        _ = air.sample(orientation: simd_quatd(angle: 3.13, axis: SIMD3(0, 0, 1)), time: 2, scale: 1800)
        let wrapped = air.sample(orientation: simd_quatd(angle: -3.13, axis: SIMD3(0, 0, 1)), time: 2.01, scale: 1800)!
        precondition(abs(wrapped.x) < 50, "Heading wrap must not jump across the screen")
        print("Passed: key agreement, session isolation, authentication, replay rejection, ATT fragmentation, malformed input, drag lifecycle, double click, right click, scroll phase and display bounds")
    }
}
