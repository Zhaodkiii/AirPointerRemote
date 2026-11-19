import AppKit
import Network
import ScreenCaptureKit

/// Main-queue session, owned by one authenticated Bluetooth peer.
final class LinkedHost: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private var listener: NWListener?
    private var channel: LinkedChannel?
    private var stream: SCStream?
    private var encoder: LinkedEncoder?
    private var pending: CMSampleBuffer?
    private var frameInFlight = false
    private var hasPicture = false
    private var pickerActive = false
    private var displayID: CGDirectDisplayID?
    private var bounds = CGRect.zero
    private var rotation: Double = 0
    private var timer: Timer?
    private var deadline = Date().addingTimeInterval(35)
    private var activity: NSObjectProtocol?
    private let mouse = PhoneMouse()
    private let focus = LinkedFocus()
    private var lastFocus: UUID?
    private var insertionResults: [UUID: Bool] = [:]
    private var lastHeartbeat = Date()
    private var frameSent = Date()
    var onEnd: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var ended = false
    var report: ((String) -> Void)?

    func start(_ offer: LinkedOffer) {
        guard !ended else { return }
        do {
            let server = try NWListener(using: offer.parameters)
            server.service = .init(name: offer.name, type: LinkedOffer.service)
            listener = server
            server.newConnectionHandler = { [weak self] conn in
                guard let self, !ended, channel == nil else { conn.cancel(); return }
                let link = LinkedChannel(conn)
                channel = link
                link.onReady = { [weak self] in self?.chooseDisplay() }
                link.onMessage = { [weak self] in self?.handle($0) }
                link.onClose = { [weak self] reason in self?.stop(reason) }
                link.start()
            }
            server.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.stop(error.localizedDescription) }
            }
            server.start(queue: .main)
        } catch { stop(error.localizedDescription); return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, name)
        }
        observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked"))
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let handle = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if name == NSApplication.didChangeScreenParametersNotification || name == NSWorkspace.screensDidSleepNotification {
                if stream == nil { return }
                // Closing the lid may move the already shared external screen to the desktop origin.
                // Keep capturing only that same, awake display with an unchanged coordinate scale.
                if activity != nil, let id = displayID, CGDisplayIsBuiltin(id) == 0,
                   CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
                   CGDisplayRotation(id) == rotation {
                    let current = CGDisplayBounds(id)
                    if current.size == bounds.size {
                        mouse.reset()
                        bounds = current
                        return
                    }
                }
                stop("Shared display changed or went to sleep. Open the lid or share an active external display.", mayReconnect: true)
                return
            }
            stop("Mac locked or went to sleep. Unlock it to share again.", mayReconnect: name == NSWorkspace.willSleepNotification)
        }
        observers.append((center, handle))
    }

    private func chooseDisplay() {
        listener?.cancel()
        deadline = Date().addingTimeInterval(90)
        report?("Choose a display to share with your paired iPhone")
        channel?.send(.init(.waiting))
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay]
        config.allowsChangingSelectedContent = false
        picker.defaultConfiguration = config
        pickerActive = true
        picker.add(self)
        picker.isActive = true
        NSApp.activate(ignoringOtherApps: true)
        picker.present(using: .display)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in self?.capture(filter) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in self?.stop("Display selection cancelled.") }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.stop(error.localizedDescription) }
    }

    private func capture(_ filter: SCContentFilter) {
        guard !ended, stream == nil else { return }
        if #available(macOS 15.2, *) { displayID = filter.includedDisplays.first?.displayID }
        // Earlier pickers do not expose the selected ID. Only one attached screen is unambiguous.
        if displayID == nil, NSScreen.screens.count == 1 { displayID = CGMainDisplayID() }
        rotation = displayID.map(CGDisplayRotation) ?? 0
        bounds = displayID.map(CGDisplayBounds) ?? .zero
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { stop("No display available."); return }
        let scale = min(1, 1280 / max(size.width, size.height))
        let config = SCStreamConfiguration()
        config.width = max(2, Int(size.width * scale) / 2 * 2)
        config.height = max(2, Int(size.height * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let encoder = LinkedEncoder(width: config.width, height: config.height) else { stop("Video encoder unavailable."); return }
        self.encoder = encoder
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main) }
        catch { stop(error.localizedDescription); return }
        let title = NSScreen.screens.first { ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }?.localizedName ?? "Mac display"
        channel?.send(.init(.ready, x: Double(config.width), y: Double(config.height), text: title))
        deadline = Date().addingTimeInterval(10)
        report?("Sharing " + title + " with iPhone")
        stream.startCapture { [weak self] error in
            if let error { DispatchQueue.main.async { self?.stop(error.localizedDescription) } }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.stop(error.localizedDescription) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !ended, self.stream === stream, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let state = SCFrameStatus(rawValue: raw) else { return }
        if state == .idle { return }
        if state == .blank || state == .suspended || state == .stopped { stop("Display unavailable. Open the lid or reconnect a display.", mayReconnect: true); return }
        guard state == .complete, sample.imageBuffer != nil else { return }
        pending = sample
        encodeLatest()
    }

    private func encodeLatest() {
        guard !frameInFlight, let sample = pending, let encoder else { return }
        pending = nil
        frameInFlight = true
        frameSent = Date()
        deadline = Date().addingTimeInterval(5)
        encoder.encode(sample) { [weak self] data in
            guard let self, !ended else { return }
            guard let data else { stop("Video encoding interrupted."); return }
            channel?.send(data, frame: true)
        }
    }

    private func tick() {
        if (stream == nil || frameInFlight || !hasPicture) && Date() > deadline { stop("Sharing timed out. Try again."); return }
        guard hasPicture else { return }
        if Date().timeIntervalSince(lastHeartbeat) > 3 {
            stop("iPhone stopped responding.")
            return
        }
        if !CGPreflightPostEventAccess() || (frameInFlight && Date().timeIntervalSince(frameSent) > 0.6) { mouse.reset() }
        channel?.send(.init(.alive, x: displayID != nil && CGPreflightPostEventAccess() ? 1 : 0))
        focus.refresh()
        if lastFocus != focus.token {
            lastFocus = focus.token
            channel?.send(.init(.focus, token: lastFocus))
        }
    }

    private func handle(_ message: LinkedMessage) {
        guard !ended else { return }
        if message.kind == .stop { stop(); return }
        guard stream != nil else { return }
        if message.kind == .alive { lastHeartbeat = Date(); return }
        if message.kind == .frameAck {
            lastHeartbeat = Date()
            if frameInFlight { frameInFlight = false; hasPicture = true; encodeLatest() }
            return
        }
        if message.kind == .keepAwake {
            setAwake(message.x == 1)
            return
        }
        if message.kind == .dragEnd {
            mouse.handle(.init(.leftUp))
            return
        }
        guard hasPicture, !frameInFlight || Date().timeIntervalSince(frameSent) < 0.6,
              CGPreflightPostEventAccess(), let displayID, CGDisplayIsActive(displayID) != 0,
              CGDisplayBounds(displayID) == bounds, message.x.isFinite, message.y.isFinite else {
            if message.kind == .insert { channel?.send(.init(.rejected, request: message.request)) }
            return
        }
        let x = min(1, max(0, message.x)), y = min(1, max(0, message.y))
        let point = CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
        switch message.kind {
        case .click, .doubleClick, .rightClick, .dragStart, .dragMove:
            mouse.position(at: point)
            switch message.kind {
            case .click: mouse.handle(.init(.leftDown)); mouse.handle(.init(.leftUp))
            case .doubleClick: mouse.handle(.init(.doubleClick))
            case .rightClick: mouse.handle(.init(.rightClick))
            case .dragStart: mouse.handle(.init(.leftDown))
            default: break
            }
        case .relative:
            let p = mouse.location
            mouse.position(at: CGPoint(x: min(bounds.maxX-1, max(bounds.minX, p.x + message.x)),
                                       y: min(bounds.maxY-1, max(bounds.minY, p.y + message.y))))
        case .currentClick, .currentDown, .currentDouble, .currentRight, .scroll:
            guard bounds.contains(mouse.location) else { return }
            switch message.kind {
            case .currentClick: mouse.handle(.init(.leftDown)); mouse.handle(.init(.leftUp))
            case .currentDown: mouse.handle(.init(.leftDown))
            case .currentDouble: mouse.handle(.init(.doubleClick))
            case .currentRight: mouse.handle(.init(.rightClick))
            default: mouse.handle(.init(.scroll, x: message.x, y: message.y))
            }
        case .insert:
            guard let request = message.request, let text = message.text else { return }
            if insertionResults[request] == nil {
                guard insertionResults.count < 4096 else { stop("Start a new sharing session to continue typing."); return }
                insertionResults[request] = focus.insert(text, token: message.token)
            }
            channel?.send(.init(insertionResults[request] == true ? .inserted : .rejected, request: request))
        default: break
        }
    }

    private func setAwake(_ enabled: Bool) {
        if enabled, activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "User is sharing a display with iPhone") }
        if !enabled, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    func stop(_ reason: String = "Screen sharing ended.", mayReconnect: Bool = false) {
        guard !ended else { return }
        ended = true
        timer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if pickerActive {
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
        }
        mouse.reset()
        setAwake(false)
        listener?.cancel()
        channel?.send(.init(.stop, x: mayReconnect ? 1 : 0, text: reason))
        let closing = channel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { closing?.close() }
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil; pending = nil; encoder = nil; channel = nil
        report?(reason)
        onEnd?()
    }
}
