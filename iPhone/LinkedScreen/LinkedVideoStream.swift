import AVFoundation
import Network
import os

/// Receives, decodes and acknowledges video independently of SwiftUI and scene callbacks.
final class LinkedVideoStream {
    private enum Playback { case waiting, playing, paused }
    private static let videoQueue = DispatchQueue(label: "cn.zhaodk.glidecue.linked-video", qos: .userInitiated)
    private var queue: DispatchQueue { Self.videoQueue }
    private let renderer: AVSampleBufferVideoRenderer
    private let controlQueue = DispatchQueue(label: "cn.zhaodk.glidecue.linked-control", qos: .userInteractive)
    private let offer: LinkedOffer
    private var videoLane: LinkedChannel?
    private var hasDedicatedVideo = false
    private let link: LinkedChannel
    private var framesWindow: [(received: Double, enqueued: Double)] = []
    private var touchWindow: [(time: Double, ms: Double)] = []
    private var probes: [UUID: Double] = [:] // controlQueue only
    private var pendingMotion: LinkedMessage?
    private var motionWrites = 0
    private var closed = false // video queue only
    private var nextProbeTime: Double = 0
    private var displaySamples: [(time: Double, count: Int)] = []
    private var samplingRenderer = false
    private var lastReport: Double = 0
    private var measurementStart: Double?
    private var recentHostTiming: (id: UInt64?, encode: Double, ack: Double, phone: Double?)?
    private var encodedSize = ""
    var onDiagnostics: ((VideoDiagnostics) -> Void)?

    private let log = Logger(subsystem: "cn.zhaodk.glidecue", category: "LinkedVideoClient")
    private var decoder = LinkedDecoder()
    private var playback: Playback = .waiting
    private var needsFirstFrame = true
    private var recoverySupported = false
    private var heartbeat: DispatchSourceTimer?
    private var backgroundParked = false
    private var lastFrame: TimeInterval?
    private var metricsStart: TimeInterval?
    private var receivedFrames = 0
    private var longestGap: TimeInterval = 0
    private var longGaps = 0
    private var enqueueTime: TimeInterval = 0

    var onClose: ((String) -> Void)?
    var onMessage: ((LinkedMessage) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onVideoRecovery: (() -> Void)?

    init(_ connection: NWConnection, offer: LinkedOffer, renderer: AVSampleBufferVideoRenderer) {
        self.offer = offer
        link = LinkedChannel(connection)
        self.renderer = renderer
    }

    func start() {
        controlQueue.async { [self] in
            link.onClose = { [weak self] reason in
                guard let self else { return }
                heartbeat?.cancel()
                heartbeat = nil
                queue.async { [self] in
                    self.closeVideo()
                    DispatchQueue.main.async { [weak self] in self?.onClose?(reason) }
                }
            }
            link.onMessage = { [weak self] message in
                guard let self else { return }
                if let reply = message.probeReply {
                    if let sent = probes.removeValue(forKey: reply) {
                        let now = ProcessInfo.processInfo.systemUptime
                        queue.async { [self] in self.touchWindow.append((now, (now - sent) * 1000)) }
                    }
                    return
                }
                queue.async { [self] in
                    if let ticket = message.videoTicket { self.openVideo(ticket); return }
                    self.receive(message)
                }
            }
            link.onFrame = { [weak self] data in
                guard let self else { return }
                let received = ProcessInfo.processInfo.systemUptime
                queue.async { [self] in
                    if !self.hasDedicatedVideo { self.render(data, received: received) }
                }
            }
            link.start(queue: controlQueue)
            let timer = DispatchSource.makeTimerSource(queue: controlQueue)
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self, !backgroundParked else { return }
                var alive = LinkedMessage(.alive)
                alive.supportsVideoLane = true
                link.send(alive)
                queue.async { [self] in self.reportDiagnostics() }
            }
            heartbeat = timer
            timer.resume()
        }
    }

    private func closeVideo() {
        videoLane?.onClose = nil
        videoLane?.close()
        videoLane = nil
    }

    private func openVideo(_ ticket: UUID) {
        guard !closed else { return }
        closeVideo()
        let videoOffer = offer.videoOffer(ticket)
        let endpoint = NWEndpoint.service(name: videoOffer.name, type: LinkedOffer.service, domain: "local.", interface: nil)
        let lane = LinkedChannel(NWConnection(to: endpoint, using: videoOffer.parameters))
        videoLane = lane
        lane.onMessage = { [weak self, weak lane] message in
            guard let self, let lane, videoLane === lane, message.kind == .ready else { return }
            hasDedicatedVideo = true
            renderer.flush(removingDisplayedImage: false)
            receive(message)
        }
        lane.onFrame = { [weak self, weak lane] packet in
            let now = ProcessInfo.processInfo.systemUptime
            guard let self, let lane, videoLane === lane, packet.count > 8 else { return }
            render(Data(packet.dropFirst(8)), received: now, id: packet.integer(at: 0, as: UInt64.self))
        }
        lane.onClose = { [weak self, weak lane] _ in
            guard let self, let lane, videoLane === lane else { return }
            videoLane = nil
            if hasDedicatedVideo && playback != .paused {
                playback = .waiting
                DispatchQueue.main.async { [weak self] in self?.onVideoRecovery?() }
            }
        }
        lane.start(queue: queue)
    }

    func send(_ message: LinkedMessage) {
        let submitted = ProcessInfo.processInfo.systemUptime
        controlQueue.async { [self] in
            var outgoing = message
            switch message.kind {
            case .relative, .click, .currentClick, .scroll, .dragStart, .dragMove, .dragEnd,
                 .doubleClick, .rightClick, .currentRight, .currentDouble, .currentDown, .gesture:
                if submitted >= nextProbeTime {
                    nextProbeTime = submitted + 0.25
                    probes = probes.filter { submitted - $0.value < 60 }
                    let probe = UUID()
                    probes[probe] = submitted
                    outgoing.controlProbe = probe
                }
            default: break
            }
            switch outgoing.kind {
            case .relative, .dragMove:
                if motionWrites == 0 {
                    writeMotion(outgoing)
                } else {
                    if let old = pendingMotion, old.kind == .relative, outgoing.kind == .relative,
                       old.videoEpoch == outgoing.videoEpoch {
                        outgoing.x += old.x
                        outgoing.y += old.y
                        if outgoing.controlProbe == nil { outgoing.controlProbe = old.controlProbe }
                    }
                    pendingMotion = outgoing
                }
            case .dragEnd, .stop, .viewing:
                pendingMotion = nil
                link.send(outgoing)
            default:
                // A click after a slide must use the slide's final location.
                if outgoing.kind != .frameAck && outgoing.kind != .alive { flushMotion() }
                link.send(outgoing)
            }
        }
    }

    private func writeMotion(_ motion: LinkedMessage) {
        motionWrites += 1
        link.send(motion) { [weak self] in
            guard let self else { return }
            motionWrites -= 1
            if motionWrites == 0 { flushMotion() }
        }
    }

    private func flushMotion() {
        guard let pendingMotion else { return }
        self.pendingMotion = nil
        writeMotion(pendingMotion)
    }

    func awaitFreshFrame(command: LinkedMessage? = nil) {
        queue.async { [self] in
            playback = .waiting
            controlQueue.async { [self] in backgroundParked = false }
            if let command { send(command) }
        }
    }

    func pause(background: Bool, command: LinkedMessage? = nil) {
        queue.async { [self] in
            framesWindow.removeAll()
            touchWindow.removeAll()
            displaySamples.removeAll()
            measurementStart = nil
            playback = .paused
            controlQueue.async { [self] in backgroundParked = background }
            if let command { send(command) }
        }
    }

    func close(keepLastFrame: Bool = false, notifyMac: Bool = false) {
        queue.async { [self] in
            closed = true
            closeVideo()
            controlQueue.async { [self] in
                heartbeat?.cancel()
                heartbeat = nil
                link.onClose = nil
                if notifyMac {
                    link.send(.init(.stop))
                    controlQueue.asyncAfter(deadline: .now() + .milliseconds(200)) { [self] in link.close() }
                } else { link.close() }
            }
            renderer.flush(removingDisplayedImage: !keepLastFrame)
        }
    }

    private func receive(_ message: LinkedMessage) {
        guard !closed else { return }
        if message.kind == .ready, playback != .paused {
            needsFirstFrame = true
            recoverySupported = hasDedicatedVideo || message.transportResume == true
            playback = .playing
            decoder = LinkedDecoder()
            lastFrame = nil
            metricsStart = nil
            receivedFrames = 0
            longestGap = 0
            longGaps = 0
            enqueueTime = 0
            if renderer.status == .failed { renderer.flush(removingDisplayedImage: true) }
        }
        if let encode = message.encodeMS, let ack = message.ackMS { recentHostTiming = (message.frameID, encode, ack, message.phoneEnqueueMS) }
        if let w = message.encodedWidth, let h = message.encodedHeight { encodedSize = "\(w) × \(h)" }
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }

    private func reportDiagnostics() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !closed, now - lastReport >= 1, let measurementStart else { return }
        lastReport = now
        let start = max(measurementStart, now - 60)
        // Keep a boundary sample to include gaps crossing the start of the window.
        if let index = framesWindow.lastIndex(where: { $0.enqueued < start }), index > 0 {
            framesWindow.removeFirst(index)
        }
        touchWindow.removeAll { $0.time < start }
        var previous = start
        var longest = 0.0, processing = 0.0
        var count = 0
        for frame in framesWindow where frame.enqueued >= start {
            longest = max(longest, frame.received - previous)
            previous = max(start, frame.received)
            processing = max(processing, frame.enqueued - frame.received)
            count += 1
        }
        longest = max(longest, now - previous)
        let touches = touchWindow.map(\.ms).sorted()
        if #available(iOS 17.4, macOS 14.4, *), !samplingRenderer {
            samplingRenderer = true
            renderer.loadVideoPerformanceMetrics { [weak self] result in
                let count = result.map { $0.totalNumberOfFrames - $0.numberOfDroppedFrames }
                guard let self else { return }
                self.queue.async { [self] in
                    self.samplingRenderer = false
                    guard let count, self.measurementStart == measurementStart else { return }
                    if let last = self.displaySamples.last, count < last.count { self.displaySamples.removeAll() }
                    self.displaySamples.append((now, count))
                }
            }
        }
        displaySamples.removeAll { $0.time < start }
        var displayFPS: Double?
        if let first = displaySamples.first, let last = displaySamples.last, last.time > first.time {
            displayFPS = Double(last.count - first.count) / (last.time - first.time)
        }
        let metrics = VideoDiagnostics(frameID: recentHostTiming?.id, phoneMS: recentHostTiming?.phone, displayFPS: displayFPS, fps: Double(count) / max(0.5, now - start),
            longestGapMS: longest * 1000, enqueueMS: processing * 1000,
            touchMS: touches.isEmpty ? nil : touches[Int(ceil(Double(touches.count) * 0.95)) - 1],
            encodeMS: recentHostTiming?.encode, ackMS: recentHostTiming?.ack,
            resolution: encodedSize, split: hasDedicatedVideo)
        DispatchQueue.main.async { [weak self] in self?.onDiagnostics?(metrics) }
    }

    private func render(_ bytes: Data, received: Double, id: UInt64? = nil) {
        guard !closed else { return }
        var acknowledgement = LinkedMessage(.frameAck)
        acknowledgement.frameID = id
        acknowledgement.receivedAt = received
        acknowledgement.frameEnqueued = playback == .playing
        guard playback == .playing else { send(acknowledgement); return }
        let started = ProcessInfo.processInfo.systemUptime
        guard renderer.status != .failed, let sample = decoder.sample(from: bytes) else {
            guard recoverySupported else {
                controlQueue.async { [self] in link.close(String(localized: "Video playback interrupted. Resume sharing to try again.")) }
                return
            }
            log.notice("Video renderer or decoder interrupted; requesting a fresh keyframe (renderer status: \(self.renderer.status.rawValue))")
            playback = .waiting
            renderer.flush(removingDisplayedImage: false)
            acknowledgement.frameEnqueued = false
            acknowledgement.requestKeyFrame = true
            send(acknowledgement)
            DispatchQueue.main.async { [weak self] in self?.onVideoRecovery?() }
            return
        }
        renderer.enqueue(sample)
        let now = ProcessInfo.processInfo.systemUptime
        acknowledgement.enqueuedAt = now
        send(acknowledgement)
        if let id { log.debug("Frame id=\(id) received=\(received) enqueued=\(now)") }
        if measurementStart == nil { measurementStart = received }
        framesWindow.append((received, now))
        if let lastFrame {
            let gap = started - lastFrame
            longestGap = max(longestGap, gap)
            if gap >= 0.25 { longGaps += 1 }
        }
        lastFrame = started
        receivedFrames += 1
        enqueueTime += now - started
        if let metricsStart, now - metricsStart >= 1 {
            let fps = Int(Double(receivedFrames) / (now - metricsStart))
            let gapMilliseconds = Int(longestGap * 1000)
            let enqueueMilliseconds = Int(enqueueTime / Double(receivedFrames) * 1000)
            log.debug("Video receive: fps=\(fps) gaps_250ms=\(self.longGaps) max_gap_ms=\(gapMilliseconds) avg_enqueue_ms=\(enqueueMilliseconds)")
            self.metricsStart = now
            receivedFrames = 0
            longestGap = 0
            longGaps = 0
            enqueueTime = 0
        } else if metricsStart == nil {
            metricsStart = now
        }
        if needsFirstFrame {
            needsFirstFrame = false
            DispatchQueue.main.async { [weak self] in self?.onFirstFrame?() }
        }
    }
}

struct VideoDiagnostics {
    let frameID: UInt64?
    let phoneMS: Double?
    let displayFPS: Double?
    let fps: Double
    let longestGapMS: Double
    let enqueueMS: Double
    let touchMS: Double?
    let encodeMS: Double?
    let ackMS: Double?
    let resolution: String
    let split: Bool
}
