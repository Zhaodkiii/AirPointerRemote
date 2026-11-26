import AppKit
#if CLOSED_LID_DESKTOP
import SwiftUI
#endif
import Network
import OSLog
import ScreenCaptureKit

/// Main-queue session, owned by one authenticated Bluetooth peer.
final class LinkedHost: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    // Only the authenticated peer that selected this display may reuse it.
    private static let preferencesKey = "linked.rememberedDisplays"
    private(set) static weak var sharing: LinkedHost?
    let peer: String
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
    var canRememberDisplay: Bool { !ended && !adaptiveRequested && selectedUUID != nil }
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
    private var sessionOffer: LinkedOffer?
    private var videoListener: NWListener?
    private var videoLink: LinkedChannel?
    private var videoCandidate: LinkedChannel?
    private var videoTicket: UUID?
    private var splitVideo = false
    private var supportsSplit = false
    private var nextVideoAttempt: TimeInterval = 0
    private var videoAttemptDeadline: TimeInterval = 0
    private var frameSequence: UInt64 = 0
    private var lastEncodeMS: Double?
    private var lastAckMS: Double?
    private var lastPhoneMS: Double?
    private var lastFrameID: UInt64?
    private var videoRepairDeadline: TimeInterval?
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
        let id: UInt64?
        let started: TimeInterval
        let generation: Int
        var sent: TimeInterval?
    }
    private let frameCapacity = 3
    private var frames: [Frame] = []
    private var encoding = false
    private var generation = 0
    private var readyAfterDrain: LinkedMessage?
    private let videoLog = Logger(subsystem: "cn.zhaodk.glidecue", category: "LinkedVideo")
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
    private let focusLog = Logger(subsystem: "cn.zhaodk.glidecue", category: "LinkedFocus")
    private var pendingKeyboardClick: UUID?
    private var leftPress: (point: CGPoint, time: TimeInterval)?
    private var lastFocus: UUID?
    private var insertionResults: [UUID: Bool] = [:]
    private var lastHeartbeat = Date()
    var onEnd: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var ended = false
    var report: ((String) -> Void)?
    private var integratedLid = false
    private var adaptiveRequested = false
    #if CLOSED_LID_DESKTOP
    private var windowPicker: NSPanel?
    private var phoneWindow: PhoneDesktopWindow?
    private var adaptiveScreen: VirtualScreen?
    private var adaptiveSize: AdaptiveDesktopSize?
    private var adaptivePendingSize: AdaptiveDesktopSize?
    private var adaptiveResizing = false
    #endif
    var closedLidPowerWarning: String?
    private var phoneSupportsTransportResume = false
    private var detachedDeadline: TimeInterval?
    private var channelReady = false
    private var everAcknowledgedPicture = false
    private var transportGeneration = 0
    private var resumeTimedOut: Bool { detachedDeadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false }
    private var canResumeTransport = false

    private enum HandoffDestination {
        case builtIn
        case lidDesktop(CGDirectDisplayID)
        case adaptive(CGDirectDisplayID)

        var closedLid: Bool {
            if case .lidDesktop = self { return true }
            return false
        }

        func matches(_ id: CGDirectDisplayID) -> Bool {
            switch self {
            case .builtIn: CGDisplayIsBuiltin(id) != 0
            case .lidDesktop(let target), .adaptive(let target): id == target
            }
        }
    }
    private struct PreviousDisplay {
        let source: CaptureSource
        let ready: LinkedMessage
        var sample: CMSampleBuffer?
    }
    private struct DisplayHandoff {
        let token: UUID
        let destination: HandoffDestination
        let completion: (Bool) -> Void
        var target: CaptureSource?
        var previous: PreviousDisplay?
        var awaitingFrame: Bool { previous != nil }
    }
    private struct CaptureSource {
        let id: CGDirectDisplayID
        let stream: SCStream
        let encoder: LinkedEncoder
        let size: CGSize
    }
    private var handoff: DisplayHandoff?
    var canSwitchToLidDisplay: Bool {
        !ended && !integratedLid && !adaptiveRequested && channelReady && hasPicture && handoff == nil &&
            backgroundDeadline == nil && !playbackPaused && displayID != nil
    }
    private var networkTimeout: TimeInterval { canResumeTransport ? 10 : 5 }

    func connectionLost() {
        // Once Linked Screen is authenticated, mouse input and liveness use TLS.
        // Bluetooth can reconnect independently during a lid transition.
        if canResumeTransport && everAcknowledgedPicture { return }
        stop("Connection to the iPhone was interrupted.", lidReconnect: integratedLid && hasPicture)
    }

    func start(_ offer: LinkedOffer, chooseDisplay: Bool = false, supportsTransportResume: Bool = false, adaptive: Bool = false) {
        guard !ended else { return }
        sessionOffer = offer
        adaptiveRequested = adaptive
        phoneSupportsTransportResume = supportsTransportResume
        do {
            let server = try NWListener(using: offer.parameters)
            server.service = .init(name: offer.name, type: LinkedOffer.service)
            listener = server
            server.newConnectionHandler = { [weak self] conn in
                guard let self, !ended, channel == nil else { conn.cancel(); return }
                let link = LinkedChannel(conn)
                channel = link
                link.onReady = { [weak self, weak link] in
                    guard let self, let link, self.channel === link, !self.ended else { return }
                    self.channelReady = true
                    if self.detachedDeadline != nil {
                        guard !self.resumeTimedOut else { self.stopResumeTimeout(); return }
                        self.resumeTransport()
                    } else if self.adaptiveRequested {
                        self.waitForAdaptiveSize()
                    } else {
                        self.chooseDisplay(forcePicker: chooseDisplay)
                    }
                }
                link.onMessage = { [weak self, weak link] message in
                    guard let self, let link, self.channel === link else { return }
                    self.handle(message)
                }
                link.onClose = { [weak self, weak link] reason in
                    guard let self, let link, self.channel === link, !self.ended else { return }
                    if self.canResumeTransport && self.everAcknowledgedPicture {
                        self.detachTransport(reason)
                    } else {
                        self.stop(reason, lidReconnect: self.integratedLid && self.hasPicture)
                    }
                }
                if detachedDeadline != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak link] in
                        guard let self, let link, self.channel === link, !self.channelReady else { return }
                        link.close("iPhone reconnection handshake timed out.")
                    }
                }
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
        // NSMenu tracks scrolling in eventTracking mode. Heartbeats and frame ACK
        // deadlines must keep running while the status item is open.
        let sessionTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.tick() }
        timer = sessionTimer
        RunLoop.main.add(sessionTimer, forMode: .common)
    }

    private func clearVideoLane() {
        videoTicket = nil
        videoListener?.cancel()
        videoListener = nil
        videoCandidate?.onClose = nil
        videoCandidate?.close()
        videoCandidate = nil
        videoLink?.onClose = nil
        videoLink?.close()
        videoLink = nil
    }

    private func discardVideoBacklog() {
        if videoRepairDeadline == nil { videoRepairDeadline = ProcessInfo.processInfo.systemUptime + 14 }
        transportGeneration += 1
        generation += 1
        frames.removeAll()
        encoding = false
        awaitingForegroundFrame = true
        recoveringFromDelay = true
        resetInputForNewFrame()
        pending = latestSample
        readyAfterDrain = readyMessage
        deadline = Date().addingTimeInterval(networkTimeout)
    }

    private func offerVideoLane(at now: TimeInterval) {
        guard let sessionOffer, videoListener == nil, videoLink == nil, now >= nextVideoAttempt else { return }
        nextVideoAttempt = now + 4
        videoAttemptDeadline = now + 3
        let ticket = UUID()
        let offer = sessionOffer.videoOffer(ticket)
        do {
            let server = try NWListener(using: offer.parameters)
            videoTicket = ticket
            videoListener = server
            server.service = .init(name: offer.name, type: LinkedOffer.service)
            server.stateUpdateHandler = { [weak self] state in
                guard let self, self.videoTicket == ticket else { return }
                switch state {
                case .ready:
                    var invitation = LinkedMessage(.alive)
                    invitation.videoTicket = ticket
                    self.channel?.send(invitation)
                case .failed: self.clearVideoLane()
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                guard let self, self.videoTicket == ticket, self.videoCandidate == nil,
                      self.videoLink == nil else { connection.cancel(); return }
                let link = LinkedChannel(connection)
                self.videoCandidate = link
                link.onReady = { [weak self, weak link] in
                    guard let self, let link, self.videoCandidate === link else { return }
                    self.videoCandidate = nil
                    self.videoLink = link
                    self.videoListener?.cancel()
                    self.videoListener = nil
                    self.splitVideo = true
                    self.nextVideoAttempt = ProcessInfo.processInfo.systemUptime + 4
                    self.discardVideoBacklog()
                    self.encodeLatest()
                }
                link.onClose = { [weak self, weak link] _ in
                    guard let self, let link else { return }
                    if self.videoCandidate === link { self.videoCandidate = nil }
                    if self.videoLink === link {
                        self.clearVideoLane()
                        self.discardVideoBacklog()
                    }
                }
                link.start()
            }
            server.start(queue: .main)
        } catch { videoLog.error("Could not start video listener") }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let handle = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if name == NSApplication.didChangeScreenParametersNotification || name == NSWorkspace.screensDidSleepNotification {
                #if CLOSED_LID_DESKTOP
                if adaptiveResizing { return }
                #endif
                if lidRecoveryDeadline != nil { return }
                if stream == nil { return }
                if lidDisplayUUID != nil && handoff?.awaitingFrame != true {
                    mouse.reset()
                    if let id = displayID, CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
                       CGDisplayBounds(id).size == bounds.size, CGDisplayRotation(id) == rotation {
                        bounds = CGDisplayBounds(id)
                    } else {
                        recoverLidCapture()
                    }
                    return
                }
                // Another display can disappear without affecting the captured display.
                if let id = displayID,
                   name == NSApplication.didChangeScreenParametersNotification || (activity != nil && CGDisplayIsBuiltin(id) == 0),
                   CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
                   CGDisplayRotation(id) == rotation {
                    let current = CGDisplayBounds(id)
                    if current.size == bounds.size {
                        mouse.reset()
                        bounds = current
                        return
                    }
                }
                if handoff?.awaitingFrame == true { failDisplayHandoff(); return }
                stop("Shared display changed or went to sleep. Open the lid or share an active external display.", mayReconnect: true)
                return
            }
            stop("Mac locked or went to sleep. Unlock it to share again.", mayReconnect: name == NSWorkspace.willSleepNotification)
        }
        observers.append((center, handle))
    }

    private func waitForAdaptiveSize() {
        #if CLOSED_LID_DESKTOP
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            stop("Allow Screen Recording for GlideCue Remote Direct on the Mac, then reconnect.")
            return
        }
        deadline = Date().addingTimeInterval(18)
        var waiting = LinkedMessage(.waiting)
        waiting.adaptiveDesktop = true
        channel?.send(waiting)
        #else
        stop("iPhone Desktop requires GlideCue Remote Direct on the Mac.")
        #endif
    }

    #if CLOSED_LID_DESKTOP
    private func requestAdaptiveSize(_ size: AdaptiveDesktopSize) {
        guard adaptiveRequested, size.valid else { return }
        adaptivePendingSize = size
        applyAdaptiveSize()
    }

    private func applyAdaptiveSize() {
        guard !ended, channelReady, !adaptiveResizing, handoff == nil,
              backgroundDeadline == nil, !playbackPaused,
              let size = adaptivePendingSize else { return }
        if size == adaptiveSize { adaptivePendingSize = nil; return }
        if adaptiveScreen != nil && (!hasPicture || stream == nil) { return }
        adaptivePendingSize = nil
        if let screen = adaptiveScreen {
            adaptiveResizing = true
            mouse.reset()
            guard screen.resize(width: UInt32(size.width), height: UInt32(size.height)) else {
                stop("The Mac could not resize iPhone Desktop.")
                return
            }
            waitForAdaptiveDisplay(screen.displayID, size: size, switching: true)
        } else {
            phoneWindow = AXIsProcessTrusted() ? PhoneDesktopWindow.focused() : nil
            guard let screen = VirtualScreen(adaptiveWidth: UInt32(size.width), height: UInt32(size.height)) else {
                stop("This Mac could not create iPhone Desktop.")
                return
            }
            adaptiveScreen = screen
            adaptiveSize = size
            listener?.cancel()
            waitForAdaptiveDisplay(screen.displayID, size: size, switching: false)
        }
    }

    private func placePhoneWindow(on display: CGDirectDisplayID, size: AdaptiveDesktopSize, remaining: Int = 3) {
        // AppKit and the target application can observe a new display later than ScreenCaptureKit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !ended, adaptiveScreen?.displayID == display, adaptiveSize == size,
                  !adaptiveResizing else { return }
            guard let window = phoneWindow else {
                showWindowPicker(on: display, size: size)
                return
            }
            if window.place(on: display) {
                windowPicker?.close()
                windowPicker = nil
                videoLog.notice("Application window placed on iPhone Desktop")
                return
            }
            if remaining > 1 {
                placePhoneWindow(on: display, size: size, remaining: remaining - 1)
            } else {
                window.restore()
                phoneWindow = nil
                showWindowPicker(on: display, size: size, retry: true)
                videoLog.notice("Window placement unavailable; continuing to share iPhone Desktop")
            }
        }
    }

    private func showWindowPicker(on display: CGDirectDisplayID, size: AdaptiveDesktopSize, retry: Bool = false) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return }
        let panel = windowPicker ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false, screen: screen)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        let picker = PhoneWindowPicker(retry: retry) { [weak self] window in
            guard let self, !ended, adaptiveScreen?.displayID == display, adaptiveSize == size else { return }
            windowPicker?.orderOut(nil)
            if let previous = phoneWindow, CFEqual(previous.element, window.element) {
                windowPicker?.close()
                windowPicker = nil
                return
            }
            phoneWindow?.restore()
            phoneWindow = window
            placePhoneWindow(on: display, size: size)
        }
        panel.contentView = NSHostingView(rootView: picker)
        let area = screen.visibleFrame
        panel.setFrame(area.insetBy(dx: 16, dy: 24), display: true)
        panel.orderFrontRegardless()
        windowPicker = panel
        videoLog.notice("Window chooser presented on iPhone Desktop")
    }

    private func waitForAdaptiveDisplay(_ id: CGDirectDisplayID, size: AdaptiveDesktopSize,
                                        switching: Bool, attempts: Int = 24) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, !self.ended, self.adaptiveScreen?.displayID == id else { return }
                if let display = content?.displays.first(where: {
                    $0.displayID == id && $0.width == size.width && $0.height == size.height
                }) {
                    guard CGDisplayIsInMirrorSet(id) == 0 else {
                        self.stop("Set iPhone Desktop to an extended display on the Mac.")
                        return
                    }
                    if switching {
                        self.switchDisplay(to: .adaptive(id)) { [weak self] ok in
                            guard let self, !ended else { return }
                            adaptiveResizing = false
                            guard ok else { stop("Could not resume sharing the resized iPhone Desktop."); return }
                            adaptiveSize = size
                            placePhoneWindow(on: id, size: size)
                        }
                    } else {
                        self.capture(SCContentFilter(display: display, excludingWindows: []), knownID: id)
                        self.placePhoneWindow(on: id, size: size)
                    }
                } else if attempts > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForAdaptiveDisplay(id, size: size, switching: switching, attempts: attempts - 1)
                    }
                } else {
                    self.stop("The Mac did not publish the requested iPhone Desktop size.")
                }
            }
        }
    }
    #endif

    private func chooseDisplay(forcePicker: Bool) {
        deadline = Date().addingTimeInterval(90)
        #if CLOSED_LID_DESKTOP
        let desktop = ClosedLidDesktop.shared
        if !forcePicker && desktop.enabled {
            integratedLid = true
            canResumeTransport = phoneSupportsTransportResume
            if !canResumeTransport { listener?.cancel() }
            var waiting = LinkedMessage(.waiting)
            waiting.closedLidDesktop = true
            channel?.send(waiting)
            desktop.prepare(for: self, peer: peer) { [weak self] result in
                guard let self, !ended else { return }
                switch result {
                case .failure(let error): stop(error.reason)
                case .success(let id): captureExactLidDisplay(id)
                }
            }
            return
        }
        #endif
        // A paired phone may enable Lid Desktop after ordinary sharing has started.
        #if CLOSED_LID_DESKTOP
        if !phoneSupportsTransportResume { listener?.cancel() }
        #else
        listener?.cancel()
        #endif
        report?(String(localized: "Choose a display to share with your paired iPhone"))
        channel?.send(.init(.waiting))
        guard !forcePicker else {
            presentPicker()
            return
        }

        #if !CLOSED_LID_DESKTOP
        let lidDisplays = NSScreen.screens.compactMap {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
        }.filter { isLidDisplay($0) && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }
        let lidUUID = lidDisplays.count == 1 ? lidDisplays.first.flatMap(displayUUID) : nil
        #else
        let lidUUID: String? = nil
        #endif
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

    #if CLOSED_LID_DESKTOP
    private func captureExactLidDisplay(_ id: CGDirectDisplayID, attempts: Int = 12) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, !self.ended, self.stream == nil else { return }
                if let display = content?.displays.first(where: { $0.displayID == id && self.isLidDisplay($0.displayID) }) {
                    self.capture(SCContentFilter(display: display, excludingWindows: []), knownID: id)
                } else if attempts > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.captureExactLidDisplay(id, attempts: attempts - 1)
                    }
                } else {
                    self.stop("The virtual display is unavailable. Open the Mac lid and try again.")
                }
            }
        }
    }
    #endif

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
        videoRepairDeadline = nil
        backgroundDeadline = ProcessInfo.processInfo.systemUptime + PhoneProtocol.LinkedLifecycle.grace
        pending = nil
        resetQualityMeasurements()
        generation += 1
        readyAfterDrain = nil
        mouse.reset()
        focus.invalidate()
        lastFocus = nil
        report?(String(localized: "Screen sharing paused while iPhone is in the background"))
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
        report?(String(localized: "Screen sharing resumed"))
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

    func lidDidClose() {
        guard integratedLid, hasPicture, !awaitingForegroundFrame else { return }
        if !viewingOnly, quality.level < 2 {
            let profile = LinkedVideoQuality.profiles[2]
            if setVideoBitRate(profile.bitrate) {
                quality.applied(2, at: ProcessInfo.processInfo.systemUptime)
                encoder?.setExpectedFrameRate(profile.fps)
            }
        }
        if !playbackPaused && backgroundDeadline == nil {
            requestFreshKeyFrame()
        }
    }

    private func stopResumeTimeout() {
        stop(integratedLid ? "Lid Desktop could not reconnect. Open the Mac lid and try sharing again."
                           : "Screen sharing could not reconnect. Try sharing again.")
    }

    private func detachTransport(_ reason: String) {
        if detachedDeadline == nil {
            detachedDeadline = ProcessInfo.processInfo.systemUptime + 30
            videoLog.notice("Lid Desktop transport interrupted; keeping display: \(reason, privacy: .public)")
        }
        clearVideoLane()
        splitVideo = false
        videoRepairDeadline = nil
        supportsSplit = false
        let oldLink = channel
        channel = nil
        channelReady = false
        oldLink?.close()
        transportGeneration += 1
        frames.removeAll()
        encoding = false
        pending = nil
        readyAfterDrain = nil
        hasPicture = false
        awaitingForegroundFrame = true
        resetInputForNewFrame()
        report?(String(localized: "Reconnecting your iPhone…"))
    }

    private func resumeTransport() {
        videoLog.notice("Lid Desktop transport reconnected; requesting a fresh keyframe")
        lastHeartbeat = Date()
        deadline = Date().addingTimeInterval(networkTimeout)
        backgroundDeadline = nil
        playbackPaused = false
        requestFreshKeyFrame()
    }

    private func resetInputForNewFrame() {
        mouse.reset()
        leftPress = nil
        pendingKeyboardClick = nil
        focus.invalidate()
        lastFocus = nil
    }

    private func requestFreshKeyFrame() {
        guard let readyMessage else { return }
        generation += 1
        awaitingForegroundFrame = true
        readyAfterDrain = stream == nil ? nil : readyMessage
        pending = latestSample
        resetInputForNewFrame()
        resetQualityMeasurements()
        encodeLatest()
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

    private func captureConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration? {
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { return nil }
        let limit: CGFloat = adaptiveRequested ? 1920 : 1280
        let scale = min(1, limit / max(size.width, size.height))
        let config = SCStreamConfiguration()
        config.width = max(2, Int(size.width * scale) / 2 * 2)
        config.height = max(2, Int(size.height * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }

    func switchToBuiltInDisplay(completion: @escaping (Bool) -> Void) {
        guard integratedLid else { completion(false); return }
        switchDisplay(to: .builtIn, completion: completion)
    }

    func switchToLidDisplay(_ id: CGDirectDisplayID, completion: @escaping (Bool) -> Void) {
        guard canSwitchToLidDisplay, isLidDisplay(id) else { completion(false); return }
        switchDisplay(to: .lidDesktop(id), completion: completion)
    }

    private func switchDisplay(to destination: HandoffDestination, completion: @escaping (Bool) -> Void) {
        guard handoff == nil, !ended, channelReady, stream != nil, backgroundDeadline == nil,
              !playbackPaused, displayID != nil else { completion(false); return }
        let token = UUID()
        handoff = DisplayHandoff(token: token, destination: destination, completion: completion)
        scheduleHandoffTimeout(token)
        findHandoffDisplay(token, destination: destination)
    }

    private func findHandoffDisplay(_ token: UUID, destination: HandoffDestination) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, self.handoff?.token == token else { return }
                guard let display = content?.displays.first(where: {
                    destination.matches($0.displayID) && CGDisplayIsActive($0.displayID) != 0 &&
                        CGDisplayIsAsleep($0.displayID) == 0
                }) else {
                    // WindowServer can publish a new virtual display after CoreGraphics reports it active.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, self.handoff?.token == token else { return }
                        self.findHandoffDisplay(token, destination: destination)
                    }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                guard let config = self.captureConfiguration(for: filter),
                      let encoder = LinkedEncoder(width: config.width, height: config.height) else {
                    self.failDisplayHandoff()
                    return
                }
                _ = encoder.setBitRate(self.videoBitRate)
                encoder.setExpectedFrameRate(self.viewingOnly ? 30 : self.quality.profile.fps)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.handoff?.target = CaptureSource(id: display.displayID, stream: stream, encoder: encoder,
                    size: CGSize(width: config.width, height: config.height))
                do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main) }
                catch { self.failDisplayHandoff(); return }
                stream.startCapture { [weak self, weak stream] error in
                    guard error != nil else { return }
                    DispatchQueue.main.async { [weak self, weak stream] in
                        guard let self, let stream, self.handoff?.target?.stream === stream else { return }
                        self.failDisplayHandoff()
                    }
                }
            }
        }
    }

    private func scheduleHandoffTimeout(_ token: UUID, awaitingFrame: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.handoff?.token == token, self.handoff?.awaitingFrame == awaitingFrame else { return }
            self.failDisplayHandoff()
        }
    }

    private func beginDisplayHandoff(_ target: CaptureSource, sample: CMSampleBuffer) {
        guard let handoff, !handoff.awaitingFrame, CGDisplayIsActive(target.id) != 0,
              CGDisplayIsAsleep(target.id) == 0, channelReady, backgroundDeadline == nil,
              !playbackPaused, let id = displayID, let stream, let encoder, let readyMessage else {
            failDisplayHandoff()
            return
        }
        let source = CaptureSource(id: id, stream: stream, encoder: encoder,
                                   size: CGSize(width: readyMessage.x, height: readyMessage.y))
        self.handoff?.previous = PreviousDisplay(source: source, ready: readyMessage, sample: latestSample)
        scheduleHandoffTimeout(handoff.token, awaitingFrame: true)
        if handoff.destination.closedLid { canResumeTransport = phoneSupportsTransportResume }
        let title = displayTitle(for: target.id)
        let ready = makeReady(size: target.size, title: title, closedLid: handoff.destination.closedLid,
                              requiresOpenLid: !handoff.destination.closedLid && CGDisplayIsBuiltin(target.id) != 0)
        installDisplay(target, ready: ready, sample: sample)
        videoLog.notice("Switching to \(title, privacy: .public) on the existing connection")
    }

    private func installDisplay(_ source: CaptureSource, ready: LinkedMessage, sample: CMSampleBuffer?) {
        stream = source.stream
        encoder = source.encoder
        displayID = source.id
        bounds = CGDisplayBounds(source.id)
        rotation = CGDisplayRotation(source.id)
        selectedUUID = displayUUID(source.id)
        displayName = ready.text ?? displayTitle(for: source.id)
        readyMessage = ready
        latestSample = sample
        lidRecoveryDeadline = nil
        deadline = Date().addingTimeInterval(networkTimeout)
        requestFreshKeyFrame()
    }

    func cancelLidDisplayHandoff() {
        if handoff?.destination.closedLid == true { failDisplayHandoff() }
    }

    private func failDisplayHandoff() {
        guard let handoff else { return }
        self.handoff = nil
        if let previous = handoff.previous {
            canResumeTransport = previous.ready.transportResume == true
            installDisplay(previous.source, ready: previous.ready, sample: previous.sample)
        }
        handoff.target?.stream.stopCapture(completionHandler: { _ in })
        handoff.completion(false)
    }

    private func finishDisplayHandoff() {
        guard let handoff, let previous = handoff.previous else { return }
        self.handoff = nil
        integratedLid = handoff.destination.closedLid
        lidDisplayUUID = integratedLid ? selectedUUID : nil
        if !integratedLid { closedLidPowerWarning = nil }
        previous.source.stream.stopCapture(completionHandler: { _ in })
        report?(String(localized: "Sharing \(displayName) with iPhone"))
        videoLog.notice("iPhone acknowledged \(self.displayName, privacy: .public); sharing continued on the same connection")
        handoff.completion(true)
    }

    private func displayTitle(for id: CGDirectDisplayID?) -> String {
        NSScreen.screens.first { ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "Mac display"
    }

    private func makeReady(size: CGSize, title: String, closedLid: Bool, requiresOpenLid: Bool) -> LinkedMessage {
        var ready = LinkedMessage(.ready, x: size.width, y: size.height, text: title)
        ready.supportsDesktopTools = adaptiveRequested ? true : nil
        ready.adaptiveDesktop = adaptiveRequested ? true : nil
        ready.closedLidDesktop = closedLid ? true : nil
        ready.requiresOpenLid = requiresOpenLid ? true : nil
        ready.transportResume = canResumeTransport ? true : nil
        ready.supportsGestures = true
        ready.backgroundResume = true
        ready.pictureInPicture = true
        return ready
    }

    private func capture(_ filter: SCContentFilter, knownID: CGDirectDisplayID? = nil) {
        guard !ended, stream == nil else { return }
        displayID = knownID
        if displayID == nil, #available(macOS 15.2, *) { displayID = filter.includedDisplays.first?.displayID }
        // Earlier pickers do not expose the selected ID. Only one attached screen is unambiguous.
        if displayID == nil, NSScreen.screens.count == 1 { displayID = CGMainDisplayID() }
        rotation = displayID.map(CGDisplayRotation) ?? 0
        bounds = displayID.map(CGDisplayBounds) ?? .zero
        guard let config = captureConfiguration(for: filter) else { stop("No display available."); return }
        guard let encoder = LinkedEncoder(width: config.width, height: config.height) else { stop("Video encoder unavailable."); return }
        self.encoder = encoder
        if integratedLid && !everAcknowledgedPicture {
            quality.applied(1, at: ProcessInfo.processInfo.systemUptime)
            _ = setVideoBitRate(quality.profile.bitrate)
        }
        if lidRecoveryDeadline != nil {
            _ = encoder.setBitRate(videoBitRate)
            encoder.setExpectedFrameRate(viewingOnly ? 30 : quality.profile.fps)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main) }
        catch { stop(error.localizedDescription); return }
        let title = displayTitle(for: displayID)
        selectedUUID = displayID.flatMap(displayUUID)
        if let id = displayID, isLidDisplay(id) { lidDisplayUUID = selectedUUID }
        videoLog.notice("Sharing display: \(title, privacy: .public)")
        displayName = title
        Self.sharing = self
        var requiresOpenLid = false
        #if CLOSED_LID_DESKTOP
        if ClosedLidDesktop.shared.supported, let id = displayID, CGDisplayIsBuiltin(id) != 0 {
            requiresOpenLid = true
        }
        #endif
        let ready = makeReady(size: CGSize(width: config.width, height: config.height), title: title,
                              closedLid: integratedLid, requiresOpenLid: requiresOpenLid)
        readyMessage = ready
        if lidRecoveryDeadline != nil {
            nextLidRecoveryAttempt = ProcessInfo.processInfo.systemUptime + 3
            readyAfterDrain = ready
        } else { channel?.send(ready) }
        deadline = Date().addingTimeInterval(10)
        report?(String(localized: "Sharing \(title) with iPhone"))
        stream.startCapture { [weak self, weak stream] error in
            if let error {
                DispatchQueue.main.async { [weak self, weak stream] in
                    guard let self, let stream, self.stream === stream else { return }
                    if self.lidRecoveryDeadline != nil { self.recoverLidCapture() }
                    else { self.stop(error.localizedDescription) }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self, weak stream] in
            guard let self, let stream else { return }
            if self.handoff?.target?.stream === stream { self.failDisplayHandoff(); return }
            guard self.stream === stream else { return }
            #if CLOSED_LID_DESKTOP
            // WindowServer can retire the old capture stream while switching modes.
            if self.adaptiveResizing && self.handoff?.awaitingFrame != true { return }
            #endif
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
        guard !ended, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let state = SCFrameStatus(rawValue: raw) else { return }
        if let previous = handoff?.previous, previous.source.stream === stream {
            if state == .complete, sample.imageBuffer != nil { handoff?.previous?.sample = sample }
            return
        }
        if let target = handoff?.target, target.stream === stream, handoff?.awaitingFrame == false {
            if state == .complete, sample.imageBuffer != nil {
                beginDisplayHandoff(target, sample: sample)
            }
            return
        }
        guard self.stream === stream, state != .idle else { return }
        if state == .blank || state == .suspended || state == .stopped {
            if handoff?.awaitingFrame == true { failDisplayHandoff() }
            else if lidDisplayUUID != nil { recoverLidCapture() }
            else { stop("Display unavailable. Open the lid or reconnect a display.", mayReconnect: true) }
            return
        }
        guard state == .complete, sample.imageBuffer != nil else { return }
        latestSample = sample
        guard channelReady, backgroundDeadline == nil, !playbackPaused else { return }
        capturedFrames += 1
        if pending != nil { replacedSamples += 1 }
        pending = sample
        encodeLatest()
    }

    private func encodeLatest() {
        guard channelReady, backgroundDeadline == nil, !playbackPaused else { return }
        if lidRecoveryDeadline != nil, pending == nil { return }
        guard !splitVideo || videoLink != nil else { return }
        if var ready = readyAfterDrain {
            guard frames.isEmpty else { return }
            readyAfterDrain = nil
            ready.videoEpoch = splitVideo ? generation : nil
            (videoLink ?? channel)?.send(ready)
        }
        guard !encoding, frames.count < frameCapacity, let sample = pending, var encoder, let image = sample.imageBuffer else { return }
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
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let scale = min(1, Double(quality.profile.longEdge) / Double(max(width, height)))
        let w = max(2, Int(Double(width) * scale) / 2 * 2)
        let h = max(2, Int(Double(height) * scale) / 2 * 2)
        var resized = false
        if encoder.width != w || encoder.height != h,
           let replacement = LinkedEncoder(width: w, height: h), replacement.setBitRate(videoBitRate) {
            replacement.setExpectedFrameRate(fps)
            self.encoder = replacement
            encoder = replacement
            resized = true
        }
        pending = nil
        encoding = true
        let frameGeneration = generation
        let transportVersion = transportGeneration
        if frames.isEmpty { deadline = Date().addingTimeInterval(networkTimeout) }
        frameSequence += 1
        let id = splitVideo ? frameSequence : nil
        frames.append(Frame(id: id, started: started, generation: frameGeneration))
        encoder.encode(sample, keyFrame: resized || (awaitingForegroundFrame && frames.count == 1)) { [weak self] data in
            guard let self, !ended, transportVersion == transportGeneration else { return }
            guard let data else {
                encoding = false
                frames.removeLast()
                if frameGeneration != generation { encodeLatest() }
                else if handoff?.awaitingFrame == true { failDisplayHandoff() }
                else { stop("Video encoding interrupted.") }
                return
            }
            frames[frames.count - 1].sent = ProcessInfo.processInfo.systemUptime
            encoding = false
            sentBytes += data.count
            if let id {
                var packet = Data()
                packet.appendInteger(id)
                packet.append(data)
                videoLink?.send(packet, frame: true)
            } else { channel?.send(data, frame: true) }
            encodeLatest()
        }
    }

    private func acknowledgeFrame(_ ack: LinkedMessage) {
        protectDelayedInput()
        guard let frame = frames.first, frame.id == ack.frameID, let sent = frame.sent else { return }
        frames.removeFirst()
        let now = ProcessInfo.processInfo.systemUptime
        let acknowledgement = now - sent
        lastEncodeMS = (sent - frame.started) * 1000
        lastAckMS = acknowledgement * 1000
        lastFrameID = frame.id
        lastPhoneMS = ack.enqueuedAt.flatMap { end in ack.receivedAt.map { max(0, end - $0) * 1000 } }
        if let id = frame.id, let received = ack.receivedAt, let enqueued = ack.enqueuedAt {
            videoLog.debug("Frame id=\(id) mac_start=\(frame.started) sent=\(sent) ack=\(now) phone_received=\(received) enqueued=\(enqueued)")
        }
        let currentPicture = ack.frameEnqueued != false && frame.generation == generation
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
            let localMS = lastPhoneMS ?? -1
            videoLog.notice("Slow frame id=\(frame.id ?? 0) phone_enqueue_ms=\(localMS): encode \(encodingMilliseconds) ms, send to ACK \(acknowledgementMilliseconds) ms, \(self.frames.count) pending")
        }
        if currentPicture, awaitingForegroundFrame, backgroundDeadline == nil,
           !viewingOnly, !playbackPaused, pending != nil, now - frame.started >= 0.6 {
            // A newer sample already exists. Show the late keyframe but keep clicks gated.
            generation += 1
            readyAfterDrain = readyMessage
            recoveringFromDelay = true
            encodeLatest()
            return
        }
        if backgroundDeadline == nil, currentPicture {
            videoRepairDeadline = nil
            if lidRecoveryDeadline != nil, stream != nil {
                lidRecoveryDeadline = nil
                videoLog.notice("Lid Desktop capture recovered and first frame acknowledged")
            }
            if recoveringFromDelay && awaitingForegroundFrame {
                // A slow recovery keyframe is still newer than the drained backlog.
                recoveringFromDelay = false
                resetQualityMeasurements()
            }
            finishDisplayHandoff()
            #if CLOSED_LID_DESKTOP
            if integratedLid { ClosedLidDesktop.shared.firstFrame(for: self) }
            #endif
            if detachedDeadline != nil {
                detachedDeadline = nil
                report?(String(localized: "Sharing \(displayName) with iPhone"))
                videoLog.notice("Lid Desktop resumed after iPhone acknowledged a fresh frame")
            }
            hasPicture = true
            everAcknowledgedPicture = true
            awaitingForegroundFrame = false
            #if CLOSED_LID_DESKTOP
            if adaptivePendingSize != nil { applyAdaptiveSize() }
            #endif
        }
        if let oldest = frames.first {
            let age = now - oldest.started
            deadline = Date().addingTimeInterval(max(0, networkTimeout - age))
        }
        encodeLatest()
    }

    private func tick() {
        if resumeTimedOut { stopResumeTimeout(); return }
        if !channelReady, detachedDeadline != nil {
            if lidRecoveryDeadline != nil && stream == nil { findLidDisplay(now: ProcessInfo.processInfo.systemUptime) }
            return
        }
        if let backgroundDeadline {
            if ProcessInfo.processInfo.systemUptime >= backgroundDeadline {
                stop("Sharing paused too long. Choose a display to share again.")
            }
            return
        }
        if let recoveryDeadline = lidRecoveryDeadline {
            let now = ProcessInfo.processInfo.systemUptime
            guard now < recoveryDeadline, Date().timeIntervalSince(lastHeartbeat) < networkTimeout else {
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
        let clock = ProcessInfo.processInfo.systemUptime
        if supportsSplit, readyMessage != nil, !playbackPaused {
            if videoListener != nil && clock >= videoAttemptDeadline { clearVideoLane() }
            if videoLink != nil, let sent = frames.first?.sent, clock - sent >= 1.2, clock >= nextVideoAttempt {
                clearVideoLane()
                discardVideoBacklog()
                videoLog.notice("Rebuilding delayed video connection; control remains active")
            }
            offerVideoLane(at: clock)
        }
        if (stream == nil || !frames.isEmpty || !hasPicture || (awaitingForegroundFrame && !playbackPaused)),
           videoRepairDeadline.map({ clock >= $0 }) ?? (Date() > deadline) {
            if canResumeTransport && everAcknowledgedPicture { detachTransport("Video frame timed out.") }
            else { stop("Sharing timed out. Try again.", lidReconnect: integratedLid && hasPicture) }
            return
        }
        guard hasPicture || (splitVideo && readyMessage != nil) else { return }
        if Date().timeIntervalSince(lastHeartbeat) > (canResumeTransport ? networkTimeout : 3) {
            if canResumeTransport { detachTransport("iPhone heartbeat timed out.") }
            else { stop("iPhone stopped responding.", lidReconnect: integratedLid) }
            return
        }
        if !viewingOnly, !playbackPaused {
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
        var canControl = displayID != nil && access && acceptsLinkedInput && !viewingOnly
        #if CLOSED_LID_DESKTOP
        if adaptiveResizing { canControl = false }
        #endif
        var heartbeat = LinkedMessage(.alive, x: hasPicture && canControl && !awaitingForegroundFrame && !pictureDelayed ? 1 : 0)
        heartbeat.videoDelayed = canControl && pictureDelayed
        heartbeat.videoBitrate = videoBitRate
        heartbeat.controlStamp = now
        heartbeat.frameID = lastFrameID
        heartbeat.phoneEnqueueMS = lastPhoneMS
        heartbeat.encodeMS = lastEncodeMS
        heartbeat.ackMS = lastAckMS
        heartbeat.encodedWidth = encoder?.width
        heartbeat.encodedHeight = encoder?.height
        heartbeat.videoFPS = viewingOnly ? 30 : quality.profile.fps
        heartbeat.closedLidPowerWarning = closedLidPowerWarning
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
        for delay in [0.07, 0.20, 0.38, 0.65] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.ended, self.backgroundDeadline == nil,
                      self.pendingKeyboardClick == id, let displayID = self.displayID,
                      CGDisplayIsActive(displayID) != 0, CGDisplayBounds(displayID) == self.bounds,
                      self.bounds.contains(point), CGPreflightPostEventAccess() else { return }
                self.focus.prepareForClick()
                self.focus.refresh()
                guard self.focus.matchesClick(at: point) else { return }
                self.pendingKeyboardClick = nil
                self.publishFocus(for: id)
            }
        }
    }

    private func replyToFocusQuery(_ query: UUID) {
        publishFocus()
        var reply = LinkedMessage(.focus, token: focus.token)
        reply.composerVersion = 1
        reply.focusQuery = query
        reply.sandboxedReceiver = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        focusLog.info("Focus query reply: editable=\(reply.token != nil)")
        channel?.send(reply)
    }

    private func handle(_ message: LinkedMessage) {
        guard !ended else { return }
        if message.kind == .stop { stop(); return }
        defer {
            if let probe = message.controlProbe {
                var echo = LinkedMessage(.alive)
                echo.probeReply = probe
                channel?.send(echo)
            }
        }
        if message.kind == .alive {
            #if CLOSED_LID_DESKTOP
            if let size = message.adaptiveSize { requestAdaptiveSize(size) }
            #endif
            if let query = message.focusQuery {
                if !viewingOnly, acceptsLinkedInput, backgroundDeadline == nil, hasPicture {
                    focus.prepareForClick()
                    focus.refresh()
                    if focus.token != nil {
                        replyToFocusQuery(query)
                    } else {
                        // Chromium may expose the focused field shortly after AX is enabled.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                            guard let self, !self.ended, !self.viewingOnly, self.acceptsLinkedInput,
                                  self.backgroundDeadline == nil, self.hasPicture else { return }
                            self.focus.refresh()
                            self.replyToFocusQuery(query)
                        }
                    }
                } else {
                    focusLog.info("Focus query skipped: viewingOnly=\(self.viewingOnly) acceptsInput=\(self.acceptsLinkedInput) background=\(self.backgroundDeadline != nil) hasPicture=\(self.hasPicture)")
                }
            }
            if message.supportsVideoLane == true { supportsSplit = true }
            lastHeartbeat = Date()
            return
        }
        if message.kind == .frameAck {
            lastHeartbeat = Date()
            acknowledgeFrame(message)
            if message.requestKeyFrame == true && (canResumeTransport || splitVideo) { requestFreshKeyFrame() }
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
        if message.kind == .dragEnd {
            guard mouse.held else { leftPress = nil; return }
            let press = leftPress
            leftPress = nil
            mouse.handle(.init(.leftUp))
            if let press, ProcessInfo.processInfo.systemUptime - press.time < 0.5,
               bounds.contains(mouse.location),
               hypot(mouse.location.x - press.point.x, mouse.location.y - press.point.y) < 5 {
                checkKeyboardClick(message.keyboardClick, at: press.point)
            }
            return
        }
        #if CLOSED_LID_DESKTOP
        if adaptiveResizing { return }
        #endif
        guard stream != nil, lidRecoveryDeadline == nil, handoff?.awaitingFrame != true,
              acceptsLinkedInput, !viewingOnly else { return }
        protectDelayedInput()
        let passiveMotion = message.kind == .relative && !mouse.held
        let currentInput = message.matchesPicture(epoch: generation, now: ProcessInfo.processInfo.systemUptime)
        guard !splitVideo || currentInput || (passiveMotion && recoveringFromDelay) else {
            if message.kind == .insert { channel?.send(.init(.rejected, request: message.request)) }
            return
        }
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
        case .desktopTool:
            #if CLOSED_LID_DESKTOP
            guard adaptiveRequested, adaptiveScreen?.displayID == displayID,
                  let size = adaptiveSize, let tool = message.desktopTool else { return }
            if tool == .windows {
                if let windowPicker, windowPicker.isVisible, phoneWindow != nil {
                    windowPicker.close()
                    self.windowPicker = nil
                } else {
                    showWindowPicker(on: displayID, size: size)
                }
            } else if windowPicker?.isVisible != true {
                PhoneDesktopWindow.send(tool, on: displayID)
            }
            #endif
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
        case .scroll:
            if let anchor = message.scrollAnchor {
                guard (0...1).contains(anchor.x), (0...1).contains(anchor.y) else { return }
                let target = CGPoint(x: bounds.minX + anchor.x * (bounds.width - 1),
                                     y: bounds.minY + anchor.y * (bounds.height - 1))
                if message.scrollPhase == 1 { mouse.position(at: target) }
                mouse.scroll(x: message.x, y: message.y, phase: message.scrollPhase ?? 0, at: target)
            } else if bounds.contains(mouse.location) {
                mouse.scroll(x: message.x, y: message.y, phase: message.scrollPhase ?? 0)
            }
        case .currentClick, .currentDown, .currentDouble, .currentRight:
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
            default: break
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

    func stop(_ reason: String = "Screen sharing ended.", mayReconnect: Bool = false, lidReconnect: Bool = false) {
        guard !ended else { return }
        videoLog.notice("Screen sharing ended: \(reason, privacy: .public)")
        ended = true
        clearVideoLane()
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
        channel?.send(.init(.stop, x: lidReconnect ? 2 : (mayReconnect ? 1 : 0), text: reason))
        let closing = channel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { closing?.close() }
        if let target = handoff?.target, target.stream !== stream {
            target.stream.stopCapture(completionHandler: { _ in })
        }
        handoff?.previous?.source.stream.stopCapture(completionHandler: { _ in })
        handoff = nil
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil; pending = nil; latestSample = nil; encoder = nil; channel = nil
        report?(Bundle.main.localizedString(forKey: reason, value: reason, table: nil))
        #if CLOSED_LID_DESKTOP
        windowPicker?.close()
        windowPicker = nil
        phoneWindow?.restore()
        phoneWindow = nil
        adaptiveScreen = nil
        ClosedLidDesktop.shared.sharingEnded(self, mayReconnect: lidReconnect)
        #endif
        onEnd?()
    }
}

#if CLOSED_LID_DESKTOP
/// AX uses the same top-left global coordinate space as CGDisplayBounds.
private final class PhoneDesktopWindow {
    let element: AXUIElement
    let original: CGRect
    private var moved = false

    private init(_ element: AXUIElement, original: CGRect) {
        self.element = element
        self.original = original
    }

    static func focused() -> PhoneDesktopWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        guard let original = frame(window) else { return nil }
        return PhoneDesktopWindow(window, original: original)
    }

    static func send(_ tool: LinkedMessage.DesktopTool, on display: CGDirectDisplayID) {
        guard let focused = focused(), CGDisplayBounds(display).contains(CGPoint(
            x: focused.original.midX, y: focused.original.midY)) else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused.element, &pid) == .success else { return }
        let code: CGKeyCode
        var flags: CGEventFlags = []
        switch tool {
        case .escape: code = 53
        case .left: code = 123
        case .right: code = 124
        case .down: code = 125
        case .up: code = 126
        case .copy: code = 8; flags = .maskCommand
        case .selectAll: code = 0; flags = .maskCommand
        case .windows: return
        }
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    struct Choice: Identifiable {
        let id = UUID()
        let app: String
        let title: String
        let window: PhoneDesktopWindow
    }

    static func choices() -> [Choice] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
        }.flatMap { app -> [Choice] in
            let owner = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(owner, 0.2)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(owner, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
                guard let rect = frame(window), rect.width > 0, rect.height > 0 else { return nil }
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                var minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
                guard (minimized as? Bool) != true else { return nil }
                return Choice(app: app.localizedName ?? "", title: title as? String ?? "",
                              window: PhoneDesktopWindow(window, original: rect))
            }
        }.sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        func read(_ key: String, _ type: AXValueType, _ pointer: UnsafeMutableRawPointer) -> Bool {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, key as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            return AXValueGetValue(raw as! AXValue, type, pointer)
        }
        guard read(kAXPositionAttribute, .cgPoint, &origin),
              read(kAXSizeAttribute, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func setFrame(_ rect: CGRect) {
        var origin = rect.origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let dimensions = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    }

    func place(on display: CGDirectDisplayID) -> Bool {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return false }
        let bounds = CGDisplayBounds(display)
        let visible = screen.visibleFrame
        let target = CGRect(x: bounds.minX + visible.minX - screen.frame.minX,
                            y: bounds.minY + screen.frame.maxY - visible.maxY,
                            width: visible.width, height: visible.height)
        moved = true
        setFrame(target)
        guard var actual = Self.frame(element) else { return false }
        // Anchor minimum-size windows against the shared edge so any excess
        // extends into empty space, rather than onto an adjacent monitor.
        if actual.width > target.width + 1 || actual.height > target.height + 1 {
            let otherBounds = NSScreen.screens.compactMap { other -> CGRect? in
                guard let number = other.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      number.uint32Value != display else { return nil }
                return CGDisplayBounds(number.uint32Value)
            }
            let originsX = [target.minX, target.maxX - actual.width]
            let originsY = [target.minY, target.maxY - actual.height]
            for x in originsX {
                for y in originsY {
                    let candidate = CGRect(origin: CGPoint(x: x, y: y), size: actual.size)
                    if otherBounds.allSatisfy({ $0.intersection(candidate).isEmpty }) {
                        setFrame(candidate)
                        if let updated = Self.frame(element) { actual = updated }
                        break
                    }
                }
                if otherBounds.allSatisfy({ $0.intersection(actual).isEmpty }) { break }
            }
        }
        let visiblePart = bounds.intersection(actual)
        guard !visiblePart.isNull, visiblePart.width >= min(target.width, actual.width) - 2,
              visiblePart.height >= min(target.height, actual.height) - 2 else { return false }
        // A minimum-width window may extend past the outside edge of the desktop.
        // Accept it only if the overflow is invisible on the Mac's other displays.
        return !NSScreen.screens.contains { other in
            guard let number = other.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value != display else { return false }
            return !CGDisplayBounds(number.uint32Value).intersection(actual).isEmpty
        }
    }

    func restore() {
        if moved { setFrame(original) }
    }
}

private struct PhoneWindowPicker: View {
    let retry: Bool
    let select: (PhoneDesktopWindow) -> Void
    @State private var choices: [PhoneDesktopWindow.Choice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择要在 iPhone 上显示的窗口").font(.largeTitle.bold())
            if retry { Text("当前窗口未能移入。可以重试，或选择另一个普通窗口。").foregroundStyle(.secondary) }
            if choices.isEmpty {
                Text("请在 Mac 上打开一个普通窗口，并允许接收端使用辅助功能，然后刷新。")
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(choices) { choice in
                        Button { select(choice.window) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choice.app).font(.title2.bold())
                                if !choice.title.isEmpty { Text(choice.title).lineLimit(2) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.buttonStyle(.bordered)
                    }
                }
            }
            Button("刷新窗口列表") { choices = PhoneDesktopWindow.choices() }
        }.padding(28).onAppear { choices = PhoneDesktopWindow.choices() }
    }
}
#endif
