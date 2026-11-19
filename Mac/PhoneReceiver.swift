import AppKit
import CoreBluetooth
import CryptoKit

/// Secure iPhone sessions on separate characteristics, alongside the legacy watch protocol.
final class PhoneReceiver {
    final class Session {
        let central: CBCentral
        let promptToken = UUID()
        var assembler = PhoneAssembler()
        var key: SymmetricKey?
        var handshakeReply: Data?
        var peerKey = Data()
        var name = "iPhone"
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var messageID: UInt16 = 0
        var macApproved = false
        var phoneApproved = false
        var authorized = false
        var lastSeen = ProcessInfo.processInfo.systemUptime
        var backgroundDeadline: TimeInterval?
        var lastStatus = 0.0
        init(_ central: CBCentral) { self.central = central }
    }

    private let identity = try? PhoneKeychain.identity()
    private let mouse = PhoneMouse()
    private var linked: LinkedHost?
    private func endSharing() {
        guard let host = linked else { return }
        linked = nil
        DispatchQueue.main.async { host.stop() }
    }
    private var sessions: [UUID: Session] = [:]
    private var notifications: [(Data, CBCentral)] = []
    private var manager: CBPeripheralManager?
    private var output: CBMutableCharacteristic?
    private var activeID: UUID?
    private var pendingID: UUID?
    // Read and written only on the main queue.
    private var pairingAlert: (token: UUID, alert: NSAlert)?
    private var locallyPaused = false
    private var remotelyPaused = false
    private var paused: Bool { locallyPaused || remotelyPaused }
    private var cachedAccess = false
    private var lastAccessCheck = 0.0
    private var movementCount = 0
    private var lastRateTime = 0.0
    private var sampleRate = 0
    var onActivity: ((String, CGPoint, Int, Bool, Bool) -> Void)?
    var onTakeControl: (() -> Void)?
    var onEndControl: (() -> Void)?
    var onState: ((String) -> Void)?
    var active: Bool { activeID != nil }

    func configure(manager: CBPeripheralManager, output: CBMutableCharacteristic) {
        reset()
        self.manager = manager
        self.output = output
        if identity == nil { onState?("Could not access secure storage for iPhone pairing. Reopen the Mac app.") }
    }

    func subscribe(_ central: CBCentral) {
        guard sessions.count < 8 else { return }
        sessions[central.identifier] = Session(central)
    }

    func unsubscribe(_ central: CBCentral) {
        if activeID == central.identifier { endSharing(); mouse.reset(); activeID = nil; onEndControl?(); onState?("iPhone disconnected") }
        if pendingID == central.identifier {
            pendingID = nil
            if let session = sessions[central.identifier] { dismissPairingAlert(token: session.promptToken) }
        }
        sessions.removeValue(forKey: central.identifier)
        notifications.removeAll { $0.1.identifier == central.identifier }
    }

    func handshakeReply(for central: CBCentral) -> Data? {
        sessions[central.identifier]?.handshakeReply
    }

    func receive(_ data: Data, from central: CBCentral, on queue: DispatchQueue) {
        guard let session = sessions[central.identifier], let packet = session.assembler.append(data) else { return }
        if packet.first == 1 {
            guard let identity, session.key == nil, pendingID == nil,
                  let hello = try? JSONDecoder().decode(PhoneProtocol.Hello.self, from: packet.dropFirst()),
                  hello.version == 1, hello.nonce.count == 32, hello.publicKey.count == 32 else { return }
            let server = PhoneProtocol.Hello(name: Host.current().localizedName ?? "Mac",
                publicKey: identity.publicKey.rawRepresentation, nonce: PhoneProtocol.nonce())
            guard let key = try? PhoneProtocol.session(privateKey: identity, client: hello, server: server, serverSide: true),
                  let encoded = try? JSONEncoder().encode(server) else { return }
            session.key = key
            session.peerKey = hello.publicKey
            session.name = String(hello.name.prefix(60))
            session.lastSeen = ProcessInfo.processInfo.systemUptime
            let reply = Data([1]) + encoded
            session.handshakeReply = reply
            print("Pairing: received iPhone hello and prepared Mac reply.")
            send(reply, to: session)
            let pin = hello.publicKey.base64EncodedString()
            let trusted = UserDefaults.standard.stringArray(forKey: "phone.trustedKeys") ?? []
            if trusted.contains(pin) {
                session.macApproved = true
            } else {
                pendingID = central.identifier
                let code = PhoneProtocol.code(key)
                let token = session.promptToken
                let name = session.name
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session else { return }
                    let alert = NSAlert()
                    alert.messageText = "Allow \(name) to control the pointer?"
                    alert.informativeText = "Confirm that your iPhone shows \(code). This allows the paired device to move, click, and drag the pointer."
                    alert.addButton(withTitle: "Codes Match — Allow")
                    alert.addButton(withTitle: "Decline")
                    NSApp.activate(ignoringOtherApps: true)
                    self.pairingAlert = (token, alert)
                    let approved = alert.runModal() == .alertFirstButtonReturn
                    if self.pairingAlert?.token == token { self.pairingAlert = nil }
                    queue.async { [weak self, weak session] in
                        guard let self, let session, self.sessions[central.identifier] === session else { return }
                        self.pendingID = nil
                        if approved {
                            session.macApproved = true
                            self.authorize(session)
                        } else {
                            self.status(session, state: "denied")
                            self.sessions.removeValue(forKey: central.identifier)
                        }
                    }
                }
            }
            status(session, state: "confirm")
            return
        }
        guard let key = session.key,
              let (sequence, plaintext) = try? PhoneProtocol.open(packet, key: key, after: session.received, direction: 2),
              let command = PhoneProtocol.Command(data: plaintext) else { return }
        session.received = sequence
        session.lastSeen = ProcessInfo.processInfo.systemUptime
        if command.action == .confirm {
            print("Pairing: iPhone confirmed the matching code.")
            session.phoneApproved = true
            authorize(session)
            return
        }
        guard session.authorized, activeID == central.identifier else { return }
        if command.action == .disconnect {
            endSharing(); mouse.reset(); activeID = nil
            onEndControl?()
            session.authorized = false
            status(session, state: "disconnected")
            return
        }
        if command.action == .linkEnd { session.backgroundDeadline = nil; endSharing(); return }
        if command.action == .heartbeat,
           let lifecycle = PhoneProtocol.LinkedLifecycle(rawValue: command.phase), let host = linked {
            switch lifecycle {
            case .background:
                if session.backgroundDeadline == nil {
                    session.backgroundDeadline = session.lastSeen + PhoneProtocol.LinkedLifecycle.grace
                    DispatchQueue.main.async { host.pauseForBackground() }
                }
            case .foreground:
                if session.backgroundDeadline != nil {
                    session.backgroundDeadline = nil
                    DispatchQueue.main.async { host.resumeFromBackground() }
                }
            }
            return
        }
        if session.backgroundDeadline != nil, ![.stop, .pause, .heartbeat].contains(command.action) { return }
        if command.action == .linkStart {
            guard !paused, let first = UInt32(exactly: command.x), let second = UInt32(exactly: command.y) else { return }
            endSharing()
            mouse.reset()
            let host = LinkedHost(peer: session.peerKey.base64EncodedString(), phoneName: session.name)
            linked = host
            let offer = LinkedOffer(key: key, first: first, second: second)
            let state = onState
            DispatchQueue.main.async { [weak self, host] in
                host.onEnd = { [weak self, weak host] in
                    queue.async {
                        if let self, self.linked === host { self.linked = nil }
                    }
                }
                host.report = state
                host.start(offer)
            }
            return
        }
        if command.action == .pause || command.action == .stop { session.backgroundDeadline = nil; endSharing() }
        if linked != nil, ![.pause, .resume, .heartbeat, .stop].contains(command.action) { return }
        if command.action == .move { movementCount += 1 }
        if command.action == .pause { remotelyPaused = true; mouse.reset() }
        if command.action == .resume { remotelyPaused = false }
        if !paused && cachedAccess {
            mouse.handle(command)
            if [.leftDown, .rightClick, .doubleClick].contains(command.action) {
                print("iPhone mouse event: \(command.action)")
                publishActivity(session, clicked: true)
            }
        }
        if command.action == .pause || command.action == .resume { status(session) }
    }

    private func authorize(_ session: Session) {
        guard session.macApproved, session.phoneApproved, !session.authorized else { return }
        mouse.reset()
        if let activeID, let old = sessions[activeID] {
            old.authorized = false
            status(old, state: "replaced")
        }
        endSharing()
        manager?.setDesiredConnectionLatency(.low, for: session.central)
        onTakeControl?()
        activeID = session.central.identifier
        remotelyPaused = false
        session.authorized = true
        session.lastSeen = ProcessInfo.processInfo.systemUptime
        var trusted = UserDefaults.standard.stringArray(forKey: "phone.trustedKeys") ?? []
        let pin = session.peerKey.base64EncodedString()
        if !trusted.contains(pin) { trusted.append(pin) }
        UserDefaults.standard.set(trusted, forKey: "phone.trustedKeys")
        print("iPhone authenticated: \(session.name), accessibility=\(cachedAccess)")
        onState?("\(session.name) connected")
        status(session)
    }

    func renderPointer(at time: TimeInterval) {
        if activeID != nil, !paused, cachedAccess { mouse.render(at: time) }
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAccessCheck > 1 {
            lastAccessCheck = now
            cachedAccess = CGPreflightPostEventAccess()
            if !cachedAccess { mouse.reset() }
        }
        if now - lastRateTime > 1 {
            sampleRate = movementCount
            movementCount = 0
            lastRateTime = now
        }
        if let activeID, let session = sessions[activeID] {
            publishActivity(session)
            if now - session.lastSeen > 0.3 { mouse.reset() }
            if now > (session.backgroundDeadline ?? session.lastSeen + 3) {
                session.authorized = false
                endSharing()
                self.activeID = nil
                onEndControl?()
                status(session, state: "timeout")
                onState?("iPhone connection timed out. Control stopped.")
            } else if session.backgroundDeadline == nil, now - session.lastStatus > 1 { status(session) }
        }
        let expired = sessions.filter { !$0.value.authorized && now - $0.value.lastSeen > 90 }.map(\.key)
        for id in expired {
            if pendingID == id {
                pendingID = nil
                if let session = sessions[id] { dismissPairingAlert(token: session.promptToken) }
            }
            sessions.removeValue(forKey: id)
        }
        flush()
    }

    func setPaused(_ value: Bool) {
        if value { endSharing() }
        locallyPaused = value
        mouse.reset()
        if let activeID, let session = sessions[activeID] { status(session) }
    }

    func revoke() {
        UserDefaults.standard.removeObject(forKey: "phone.trustedKeys")
        reset()
    }

    private func dismissPairingAlert(token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let prompt = self.pairingAlert, prompt.token == token,
                  NSApp.modalWindow === prompt.alert.window else { return }
            NSApp.abortModal()
            prompt.alert.window.orderOut(nil)
        }
    }

    func reset() {
        endSharing()
        if let pendingID, let session = sessions[pendingID] { dismissPairingAlert(token: session.promptToken) }
        mouse.reset()
        if activeID != nil { onEndControl?() }
        sessions.removeAll()
        notifications.removeAll()
        activeID = nil
        pendingID = nil
    }

    private func publishActivity(_ session: Session, clicked: Bool = false) {
        let point = mouse.location
        let bounds = Displays.bounds(containing: point)
        let normalized = CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
        onActivity?(session.name, normalized, sampleRate, clicked, paused || !cachedAccess)
    }

    private func status(_ session: Session, state: String = "ready") {
        guard let key = session.key else { return }
        let status = PhoneProtocol.Status(state: state, name: Host.current().localizedName ?? "Mac",
            accessibility: cachedAccess, paused: paused)
        guard let data = try? JSONEncoder().encode(status) else { return }
        session.sent += 1
        guard let encrypted = try? PhoneProtocol.seal(data, key: key, sequence: session.sent, direction: 3) else { return }
        send(encrypted, to: session)
        session.lastStatus = ProcessInfo.processInfo.systemUptime
    }

    private func send(_ data: Data, to session: Session) {
        guard notifications.count < 256 else { reset(); return }
        session.messageID &+= 1
        notifications += PhoneProtocol.fragments(data, mtu: session.central.maximumUpdateValueLength,
            id: session.messageID).map { ($0, session.central) }
        flush()
    }

    func flush() {
        guard let manager, let output else { return }
        while let first = notifications.first {
            guard manager.updateValue(first.0, for: output, onSubscribedCentrals: [first.1]) else { return }
            notifications.removeFirst()
        }
    }
}
