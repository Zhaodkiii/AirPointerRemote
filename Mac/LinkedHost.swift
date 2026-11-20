import AppKit
import Network
import OSLog
import ScreenCaptureKit

/// Main-queue session, owned by one authenticated Bluetooth peer.
final class LinkedHost: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    // Only the authenticated peer that selected this display may reuse it.
    private static let preferencesKey = "linked.rememberedDisplays"
    private(set) static weak var sharing: LinkedHost?
    private let peer: String
    let phoneName: String
    private(set) var displayName = ""
    private var selectedUUID: String?

    init(peer: String, phoneName: String) {
        self.peer = peer
        self.phoneName = phoneName
        super.init()
    }

    private static var remembered: [String: String] {
        UserDefaults.standard.dictionary(forKey: preferencesKey) as? [String: String] ?? [:]
    }
    static var hasRememberedDisplays: Bool { !remembered.isEmpty }
    static func forgetAllDisplays() { UserDefaults.standard.removeObject(forKey: preferencesKey) }
    var canRememberDisplay: Bool { !ended && selectedUUID != nil }
    var remembersDisplay: Bool { selectedUUID != nil && Self.remembered[peer] == selectedUUID }

    func setRemembered(_ enabled: Bool) {
        guard canRememberDisplay else { return }
        var choices = Self.remembered
        choices[peer] = enabled ? selectedUUID : nil
        UserDefaults.standard.set(choices, forKey: Self.preferencesKey)
    }

    private func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private var listener: NWListener?
    private var channel: LinkedChannel?
    private var stream: SCStream?
    private var encoder: LinkedEncoder?
    private var pending: CMSampleBuffer?
    private var latestSample: CMSampleBuffer?
    private var backgroundDeadline: TimeInterval?
    private var readyMessage: LinkedMessage?
    private var lidDisplayUUID: String?
    private var lidRecoveryDeadline: TimeInterval?
    private var nextLidRecoveryAttempt: TimeInterval = 0
    private var findingLidDisplay = false
    // TCP preserves frame order. Keep the pipeline bounded while retaining
    // the latest unencoded sample when the receiver falls behind.
    private struct Frame {
        let started: TimeInterval
        let generation: Int
        var sent: TimeInterval?
    }
    private let frameCapacity = 3
    private var frames: [Frame] = []
    private var encoding = false
    private var generation = 0
    private var readyAfterDrain: LinkedMessage?
    private let videoLog = Logger(subsystem: "com.daokaihua.airpointerremote", category: "LinkedVideo")
    private var lastStallLog: TimeInterval = 0
    private var lastSlowFrameLog: TimeInterval = 0
    private var recoveringFromDelay = false
    private var pictureDelayed: Bool {
        recoveringFromDelay || oldestFrameAge >= 0.6
    }

    private var oldestFrameAge: TimeInterval {
        guard let oldest = frames.first else { return 0 }
        return ProcessInfo.processInfo.systemUptime - oldest.started
    }
    var acceptsLinkedInput = true
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
    private var pendingKeyboardClick: UUID?
    private var leftPress: (point: CGPoint, time: TimeInterval)?
    private var lastFocus: UUID?
    private var insertionResults: [UUID: Bool] = [:]
    private var lastHeartbeat = Date()
    var onEnd: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var ended = false
    var report: ((String) -> Void)?

    func start(_ offer: LinkedOffer, chooseDisplay: Bool = false) {
        guard !ended else { return }
        do {
            let server = try NWListener(using: offer.parameters)
            server.service = .init(name: offer.name, type: LinkedOffer.service)
            listener = server
            server.newConnectionHandler = { [weak self] conn in
                guard let self, !ended, channel == nil else { conn.cancel(); return }
                let link = LinkedChannel(conn)
                channel = link
                link.onReady = { [weak self] in self?.chooseDisplay(forcePicker: chooseDisplay) }
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
                if lidRecoveryDeadline != nil { return }
                if stream == nil { return }
                if lidDisplayUUID != nil {
                    mouse.reset()
                    if let id = displayID, CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
                       CGDisplayBounds(id).size == bounds.size, CGDisplayRotation(id) == rotation {
                        bounds = CGDisplayBounds(id)
                    } else {
                        recoverLidCapture()
                    }
                    return
                }
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

    private func chooseDisplay(forcePicker: Bool) {
        listener?.cancel()
        deadline = Date().addingTimeInterval(90)
        report?("Choose a display to share with your paired iPhone")
        channel?.send(.init(.waiting))
        guard !forcePicker else {
            presentPicker()
            return
        }

        let lidDisplays = NSScreen.screens.compactMap {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
        }.filter { isLidDisplay($0) && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }
        let lidUUID = lidDisplays.count == 1 ? lidDisplays.first.flatMap(displayUUID) : nil
        let rememberedUUID = Self.remembered[peer]
        guard let targetUUID = lidUUID ?? rememberedUUID, CGPreflightScreenCaptureAccess() else {
            presentPicker()
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                let matches = content?.displays.filter {
                    let id = $0.displayID
                    return self.displayUUID(id) == targetUUID &&
                        (lidUUID == nil || self.isLidDisplay(id)) &&
                        CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
                } ?? []
                guard (lidUUID != nil || Self.remembered[self.peer] == targetUUID),
                      matches.count == 1, let display = matches.first else {
                    self.presentPicker()
                    return
                }
                self.capture(SCContentFilter(display: display, excludingWindows: []), knownID: display.displayID)
            }
        }
    }

    private func presentPicker() {
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

    func pauseForBackground() {
        guard !ended, readyMessage != nil, backgroundDeadline == nil else { return }
        backgroundDeadline = ProcessInfo.processInfo.systemUptime + PhoneProtocol.LinkedLifecycle.grace
        pending = nil
        resetQualityMeasurements()
        generation += 1
        readyAfterDrain = nil
        mouse.reset()
        focus.invalidate()
        lastFocus = nil
        report?("Screen sharing paused while iPhone is in the background")
    }

    func resumeFromBackground() {
        guard !ended, let backgroundDeadline, let readyMessage else { return }
        guard ProcessInfo.processInfo.systemUptime < backgroundDeadline else {
            stop("Sharing paused too long. Choose a display to share again.")
            return
        }
        self.backgroundDeadline = nil
        if lidRecoveryDeadline != nil {
            lidRecoveryDeadline = ProcessInfo.processInfo.systemUptime + 10
        }
        viewingOnly = false
        _ = setVideoBitRate(quality.profile.bitrate)
        encoder?.setExpectedFrameRate(quality.profile.fps)
        playbackPaused = false
        hasPicture = false
        lastHeartbeat = Date()
        deadline = Date().addingTimeInterval(10)
        pending = latestSample
        // Send the resume marker only after the old frames have drained.
        // The phone ignores old frames until it receives this marker.
        awaitingForegroundFrame = true
        readyAfterDrain = readyMessage
        encodeLatest()
        report?("Screen sharing resumed")
    }

    private var awaitingForegroundFrame = false
    private var viewingOnly = false
    private var playbackPaused = false
    private static let pipBitRate = 1_400_000
    private static let congestedPiPBitRate = 650_000
    private var videoBitRate = LinkedEncoder.desktopBitRate
    private var quality = LinkedVideoQuality()
    private var nextEncodeTime: TimeInterval = 0
    private var encodeWakeScheduled = false
    private var lastMetricsTime = ProcessInfo.processInfo.systemUptime
    private var capturedFrames = 0
    private var replacedSamples = 0
    private var sentBytes = 0
    private var slowPiPAcks = 0
    private var fastPiPAcks = 0

    private func setVideoBitRate(_ rate: Int) -> Bool {
        guard rate != videoBitRate else { return true }
        guard encoder?.setBitRate(rate) == true else {
            videoLog.error("Could not set desktop bitrate to \(rate) bits/s")
            return false
        }
        videoBitRate = rate
        videoLog.notice("Desktop bitrate target: \(rate) bits/s")
        return true
    }

    private func resetQualityMeasurements() {
        quality.resetMeasurements()
        nextEncodeTime = 0
        recoveringFromDelay = false
        slowPiPAcks = 0
        fastPiPAcks = 0
    }

    private func evaluateQuality() {
        let now = ProcessInfo.processInfo.systemUptime
        if let level = quality.evaluate(now: now, oldestAge: oldestFrameAge,
                                        windowFull: frames.count == frameCapacity) {
            let profile = LinkedVideoQuality.profiles[level]
            // Cool down even if VideoToolbox rejects the requested bitrate.
            let appliedLevel = setVideoBitRate(profile.bitrate) ? level : quality.level
            quality.applied(appliedLevel, at: now)
            encoder?.setExpectedFrameRate(quality.profile.fps)
            nextEncodeTime = 0
        }
    }

    private func protectDelayedInput() {
        guard oldestFrameAge >= 0.6, hasPicture, !awaitingForegroundFrame,
              !viewingOnly, !playbackPaused, backgroundDeadline == nil,
              let readyMessage else { return }
        recoveringFromDelay = true
        mouse.reset()
        leftPress = nil
        pendingKeyboardClick = nil
        generation += 1
        awaitingForegroundFrame = true
        readyAfterDrain = readyMessage
        pending = latestSample
        nextEncodeTime = 0
    }

    private func updateViewing(_ mode: Double) {
        guard mode == 0 || mode == 1 || mode == 2 else { return }
        let wasViewing = viewingOnly
        viewingOnly = mode != 0
        if viewingOnly != wasViewing {
            resetQualityMeasurements()
            if viewingOnly { generation += 1 }
            _ = setVideoBitRate(viewingOnly ? Self.pipBitRate : quality.profile.bitrate)
            encoder?.setExpectedFrameRate(viewingOnly ? 30 : quality.profile.fps)
        }
        if viewingOnly {
            mouse.reset()
            leftPress = nil
            pendingKeyboardClick = nil
            focus.invalidate()
            lastFocus = nil
        }
        if mode == 2 {
            resetQualityMeasurements()
            playbackPaused = true
            pending = nil
        } else if playbackPaused || mode == 0 {
            playbackPaused = false
            guard let readyMessage else { return }
            generation += 1
            pending = latestSample
            awaitingForegroundFrame = true
            readyAfterDrain = readyMessage
            deadline = Date().addingTimeInterval(5)
            encodeLatest()
        }
    }

    private func isLidDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x4c44 && CGDisplayModelNumber(id) == 1 &&
            CGDisplaySerialNumber(id) == 1
    }

    private func recoverLidCapture() {
        guard CGPreflightScreenCaptureAccess() else {
            stop("Allow Screen Recording on the Mac to restore Lid Desktop after closing the lid.")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if lidRecoveryDeadline == nil {
            lidRecoveryDeadline = now + 10
            nextLidRecoveryAttempt = now + 0.5
            videoLog.notice("Lid Desktop capture interrupted; recovering the selected display")
        }
        generation += 1
        hasPicture = false
        awaitingForegroundFrame = true
        pending = nil
        latestSample = nil
        readyAfterDrain = nil
        mouse.reset()
        leftPress = nil
        pendingKeyboardClick = nil
        focus.invalidate()
        lastFocus = nil
        resetQualityMeasurements()
        let oldStream = stream
        stream = nil
        oldStream?.stopCapture(completionHandler: { _ in })
        channel?.send(.init(.alive, x: 0))
    }

    private func findLidDisplay(now: TimeInterval) {
        guard !findingLidDisplay, !encoding, frames.isEmpty,
              now >= nextLidRecoveryAttempt, let lidDisplayUUID else { return }
        findingLidDisplay = true
        nextLidRecoveryAttempt = now + 1
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.findingLidDisplay = false
                guard !self.ended, self.lidRecoveryDeadline != nil, self.stream == nil else { return }
                let matches = content?.displays.filter {
                    let id = $0.displayID
                    return self.isLidDisplay(id) && self.displayUUID(id) == lidDisplayUUID &&
                        CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
                } ?? []
                guard matches.count == 1, let display = matches.first else { return }
                self.capture(SCContentFilter(display: display, excludingWindows: []), knownID: display.displayID)
            }
        }
    }

    private func capture(_ filter: SCContentFilter, knownID: CGDirectDisplayID? = nil) {
        guard !ended, stream == nil else { return }
        displayID = knownID
        if displayID == nil, #available(macOS 15.2, *) { displayID = filter.includedDisplays.first?.displayID }
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
        if lidRecoveryDeadline != nil {
            _ = encoder.setBitRate(videoBitRate)
            encoder.setExpectedFrameRate(viewingOnly ? 30 : quality.profile.fps)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main) }
        catch { stop(error.localizedDescription); return }
        let title = NSScreen.screens.first { ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }?.localizedName ?? "Mac display"
        selectedUUID = displayID.flatMap(displayUUID)
        if let id = displayID, isLidDisplay(id) { lidDisplayUUID = selectedUUID }
        videoLog.notice("Sharing display: \(title, privacy: .public)")
        displayName = title
        Self.sharing = self
        var ready = LinkedMessage(.ready, x: Double(config.width), y: Double(config.height), text: title)
        ready.supportsGestures = true
        ready.backgroundResume = true
        ready.pictureInPicture = true
        readyMessage = ready
        if lidRecoveryDeadline != nil {
            nextLidRecoveryAttempt = ProcessInfo.processInfo.systemUptime + 3
            readyAfterDrain = ready
        } else { channel?.send(ready) }
        deadline = Date().addingTimeInterval(10)
        report?("Sharing " + title + " with iPhone")
        stream.startCapture { [weak self] error in
            if let error {
                DispatchQueue.main.async { [weak stream] in
                    guard let self, let stream, self.stream === stream else { return }
                    if self.lidRecoveryDeadline != nil { self.recoverLidCapture() }
                    else { self.stop(error.localizedDescription) }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self, weak stream] in
            guard let self, let stream, self.stream === stream else { return }
            let failure = error as NSError
            if self.lidDisplayUUID != nil,
               failure.domain == SCStreamErrorDomain, [-3821, -3815, -3814, -3811].contains(failure.code) {
                self.recoverLidCapture()
            } else {
                self.stop(error.localizedDescription)
            }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !ended, self.stream === stream, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let state = SCFrameStatus(rawValue: raw) else { return }
        if state == .idle { return }
        if state == .blank || state == .suspended || state == .stopped {
            if lidDisplayUUID != nil { recoverLidCapture() }
            else { stop("Display unavailable. Open the lid or reconnect a display.", mayReconnect: true) }
            return
        }
        guard state == .complete, sample.imageBuffer != nil else { return }
        latestSample = sample
        guard backgroundDeadline == nil, !playbackPaused else { return }
        capturedFrames += 1
        if pending != nil { replacedSamples += 1 }
        pending = sample
        encodeLatest()
    }

    private func encodeLatest() {
        guard backgroundDeadline == nil, !playbackPaused else { return }
        if lidRecoveryDeadline != nil, pending == nil { return }
        if let ready = readyAfterDrain {
            guard frames.isEmpty else { return }
            readyAfterDrain = nil
            channel?.send(ready)
        }
        guard !encoding, frames.count < frameCapacity, let sample = pending, let encoder else { return }
        if awaitingForegroundFrame, !frames.isEmpty { return }
        let started = ProcessInfo.processInfo.systemUptime
        let fps = viewingOnly ? 30 : quality.profile.fps
        if fps < 30, !awaitingForegroundFrame, started < nextEncodeTime {
            if !encodeWakeScheduled {
                encodeWakeScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (nextEncodeTime - started)) { [weak self] in
                    guard let self, !ended else { return }
                    encodeWakeScheduled = false
                    encodeLatest()
                }
            }
            return
        }
        let frameInterval = 1 / Double(fps)
        nextEncodeTime = max(nextEncodeTime + frameInterval, started + frameInterval / 2)
        pending = nil
        encoding = true
        let frameGeneration = generation
        if frames.isEmpty { deadline = Date().addingTimeInterval(5) }
        frames.append(Frame(started: started, generation: frameGeneration))
        encoder.encode(sample, keyFrame: awaitingForegroundFrame && frames.count == 1) { [weak self] data in
            guard let self, !ended else { return }
            guard let data else { stop("Video encoding interrupted."); return }
            frames[frames.count - 1].sent = ProcessInfo.processInfo.systemUptime
            encoding = false
            sentBytes += data.count
            channel?.send(data, frame: true)
            encodeLatest()
        }
    }

    private func acknowledgeFrame(enqueued: Bool) {
        protectDelayedInput()
        guard let frame = frames.first, let sent = frame.sent else { return }
        frames.removeFirst()
        let now = ProcessInfo.processInfo.systemUptime
        let acknowledgement = now - sent
        let currentPicture = enqueued && frame.generation == generation
        if currentPicture && !awaitingForegroundFrame && backgroundDeadline == nil && !playbackPaused {
            if !viewingOnly { quality.record(now: now, delay: acknowledgement) }
        }
        if currentPicture && viewingOnly && !playbackPaused && !awaitingForegroundFrame {
            slowPiPAcks = acknowledgement > 0.18 ? slowPiPAcks + 1 : 0
            fastPiPAcks = acknowledgement < 0.08 ? fastPiPAcks + 1 : 0
            if slowPiPAcks == 3 { _ = setVideoBitRate(Self.congestedPiPBitRate) }
            if fastPiPAcks == 60 { _ = setVideoBitRate(Self.pipBitRate) }
        }
        if now - frame.started >= 0.12, now - lastSlowFrameLog >= 1 {
            lastSlowFrameLog = now
            let encodingMilliseconds = Int((sent - frame.started) * 1000)
            let acknowledgementMilliseconds = Int(acknowledgement * 1000)
            videoLog.notice("Slow frame: encode \(encodingMilliseconds) ms, send to ACK \(acknowledgementMilliseconds) ms, \(self.frames.count) pending")
        }
        if backgroundDeadline == nil, currentPicture {
            if lidRecoveryDeadline != nil, stream != nil {
                lidRecoveryDeadline = nil
                videoLog.notice("Lid Desktop capture recovered and first frame acknowledged")
            }
            if recoveringFromDelay && awaitingForegroundFrame {
                // A slow recovery keyframe is still newer than the drained backlog.
                recoveringFromDelay = false
                resetQualityMeasurements()
            }
            hasPicture = true
            awaitingForegroundFrame = false
        }
        if let oldest = frames.first {
            let age = now - oldest.started
            deadline = Date().addingTimeInterval(max(0, 5 - age))
        }
        encodeLatest()
    }

    private func tick() {
        if let backgroundDeadline {
            if ProcessInfo.processInfo.systemUptime >= backgroundDeadline {
                stop("Sharing paused too long. Choose a display to share again.")
            }
            return
        }
        if let recoveryDeadline = lidRecoveryDeadline {
            let now = ProcessInfo.processInfo.systemUptime
            guard now < recoveryDeadline, Date().timeIntervalSince(lastHeartbeat) < 5 else {
                stop("Lid Desktop did not resume. Open the lid and share Lid Desktop again.")
                return
            }
            channel?.send(.init(.alive, x: 0))
            if stream == nil {
                findLidDisplay(now: now)
            } else if latestSample == nil, now >= nextLidRecoveryAttempt {
                recoverLidCapture()
            }
            return
        }
        if (stream == nil || !frames.isEmpty || !hasPicture || (awaitingForegroundFrame && !playbackPaused)),
           Date() > deadline {
            stop("Sharing timed out. Try again.")
            return
        }
        guard hasPicture else { return }
        if Date().timeIntervalSince(lastHeartbeat) > 3 {
            stop("iPhone stopped responding.")
            return
        }
        if !viewingOnly, !playbackPaused, hasPicture {
            evaluateQuality()
        }
        protectDelayedInput()
        encodeLatest()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMetricsTime >= 1 {
            if capturedFrames > 0 || sentBytes > 0 || !frames.isEmpty {
                let bitrate = Int(Double(sentBytes * 8) / (now - lastMetricsTime))
                let oldestMilliseconds = Int(oldestFrameAge * 1000)
                videoLog.debug("Video window: captured=\(self.capturedFrames) replaced=\(self.replacedSamples) sent_bps=\(bitrate) in_flight=\(self.frames.count) oldest_ms=\(oldestMilliseconds)")
            }
            lastMetricsTime = now
            capturedFrames = 0
            replacedSamples = 0
            sentBytes = 0
        }
        let access = CGPreflightPostEventAccess()
        if !access || (pictureDelayed && mouse.held) { mouse.reset() }
        if pictureDelayed {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastStallLog >= 1 {
                lastStallLog = now
                videoLog.notice("Waiting for video acknowledgement; screen-positioned actions paused")
            }
        }
        let canControl = displayID != nil && access && acceptsLinkedInput && !viewingOnly
        var heartbeat = LinkedMessage(.alive, x: canControl && !awaitingForegroundFrame && !pictureDelayed ? 1 : 0)
        heartbeat.videoDelayed = canControl && pictureDelayed
        heartbeat.videoBitrate = videoBitRate
        heartbeat.videoFPS = viewingOnly ? 30 : quality.profile.fps
        channel?.send(heartbeat)
        if !viewingOnly { focus.refreshInBackground { [weak self] in self?.publishFocus() } }
    }

    private func publishFocus(for click: UUID? = nil) {
        guard !viewingOnly, lastFocus != focus.token || click != nil else { return }
        lastFocus = focus.token
        var update = LinkedMessage(.focus, token: lastFocus)
        update.composerVersion = 1
        update.keyboardClick = click
        channel?.send(update)
    }

    private func checkKeyboardClick(_ id: UUID?, at point: CGPoint) {
        pendingKeyboardClick = id
        guard let id else { return }
        // The remote app updates focus after consuming the posted mouse event.
        for delay in [0.07, 0.20, 0.38] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.ended, self.backgroundDeadline == nil,
                      self.pendingKeyboardClick == id, let displayID = self.displayID,
                      CGDisplayIsActive(displayID) != 0, CGDisplayBounds(displayID) == self.bounds,
                      self.bounds.contains(point), CGPreflightPostEventAccess() else { return }
                self.focus.refresh()
                guard self.focus.matchesClick(at: point) else { return }
                self.pendingKeyboardClick = nil
                self.publishFocus(for: id)
            }
        }
    }

    private func handle(_ message: LinkedMessage) {
        guard !ended else { return }
        if message.kind == .stop { stop(); return }
        if message.kind == .alive { lastHeartbeat = Date(); return }
        if message.kind == .frameAck {
            lastHeartbeat = Date()
            acknowledgeFrame(enqueued: message.frameEnqueued != false)
            return
        }
        guard backgroundDeadline == nil else { return }
        if message.kind == .keepAwake {
            setAwake(message.x == 1)
            return
        }
        if message.kind == .viewing {
            updateViewing(message.x)
            return
        }
        guard stream != nil, lidRecoveryDeadline == nil, acceptsLinkedInput, !viewingOnly else { return }
        protectDelayedInput()
        if message.kind == .dragEnd {
            let press = mouse.held ? leftPress : nil
            leftPress = nil
            mouse.handle(.init(.leftUp))
            if let press, ProcessInfo.processInfo.systemUptime - press.time < 0.5,
               bounds.contains(mouse.location),
               hypot(mouse.location.x - press.point.x, mouse.location.y - press.point.y) < 5 {
                checkKeyboardClick(message.keyboardClick, at: press.point)
            }
            return
        }
        let passiveMotion = message.kind == .relative && !mouse.held
        guard !awaitingForegroundFrame || (recoveringFromDelay && passiveMotion),
              hasPicture, passiveMotion || !pictureDelayed,
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
            case .click:
                mouse.handle(.init(.leftDown))
                mouse.handle(.init(.leftUp))
                checkKeyboardClick(message.keyboardClick, at: point)
            case .doubleClick:
                mouse.handle(.init(.doubleClick))
                checkKeyboardClick(message.keyboardClick, at: point)
            case .rightClick:
                pendingKeyboardClick = nil
                mouse.handle(.init(.rightClick))
            case .dragStart:
                pendingKeyboardClick = nil
                leftPress = nil
                mouse.handle(.init(.leftDown))
            default: break
            }
        case .gesture:
            if let gesture = message.padGesture, gesture.isSystemAction || bounds.contains(mouse.location) {
                mouse.perform(gesture)
            }
        case .relative:
            let p = mouse.location
            mouse.position(at: CGPoint(x: min(bounds.maxX-1, max(bounds.minX, p.x + message.x)),
                                       y: min(bounds.maxY-1, max(bounds.minY, p.y + message.y))))
            if let press = leftPress, hypot(mouse.location.x - press.point.x, mouse.location.y - press.point.y) >= 5 {
                leftPress = nil
            }
        case .currentClick, .currentDown, .currentDouble, .currentRight, .scroll:
            guard bounds.contains(mouse.location) else { return }
            switch message.kind {
            case .currentClick:
                let point = mouse.location
                mouse.handle(.init(.leftDown))
                mouse.handle(.init(.leftUp))
                checkKeyboardClick(message.keyboardClick, at: point)
            case .currentDown:
                pendingKeyboardClick = nil
                leftPress = (mouse.location, ProcessInfo.processInfo.systemUptime)
                mouse.handle(.init(.leftDown))
            case .currentDouble:
                let point = mouse.location
                mouse.handle(.init(.doubleClick))
                checkKeyboardClick(message.keyboardClick, at: point)
            case .currentRight:
                pendingKeyboardClick = nil
                mouse.handle(.init(.rightClick))
            default: mouse.handle(.init(.scroll, x: message.x, y: message.y, phase: message.scrollPhase ?? 0))
            }
        case .insert:
            guard let request = message.request, let text = message.text else { return }
            if message.readSelection == true {
                guard let selection = focus.readSelection(token: message.token) else {
                    channel?.send(.init(.rejected, request: request)); return
                }
                var reply = LinkedMessage(.inserted, token: message.token, request: request, text: selection.text)
                reply.selection = selection.id
                reply.styles = selection.styles
                channel?.send(reply)
                return
            }
            if insertionResults[request] == nil {
                guard insertionResults.count < 4096 else { stop("Start a new sharing session to continue typing."); return }
                insertionResults[request] = focus.commit(text, message: message)
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
        videoLog.notice("Screen sharing ended: \(reason, privacy: .public)")
        ended = true
        if Self.sharing === self { Self.sharing = nil }
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
        stream = nil; pending = nil; latestSample = nil; encoder = nil; channel = nil
        report?(reason)
        onEnd?()
    }
}
