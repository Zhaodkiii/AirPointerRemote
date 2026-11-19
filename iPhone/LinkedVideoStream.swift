import AVFoundation
import Network
import os

/// Receives, decodes and acknowledges video independently of SwiftUI and scene callbacks.
final class LinkedVideoStream {
    private enum Playback { case waiting, playing, paused }
    private static let videoQueue = DispatchQueue(label: "com.daokaihua.airpointerremote.linked-video", qos: .userInitiated)
    private var queue: DispatchQueue { Self.videoQueue }
    private let renderer: AVSampleBufferVideoRenderer
    private let link: LinkedChannel
    private let log = Logger(subsystem: "com.daokaihua.airpointerremote", category: "LinkedVideoClient")
    private var decoder = LinkedDecoder()
    private var playback: Playback = .waiting
    private var needsFirstFrame = true
    private var heartbeat: DispatchSourceTimer?
    private var backgroundParked = false
    private var lastFrame: TimeInterval?
    private var lastLog: TimeInterval = 0

    var onClose: ((String) -> Void)?
    var onMessage: ((LinkedMessage) -> Void)?
    var onFirstFrame: (() -> Void)?

    init(_ connection: NWConnection, renderer: AVSampleBufferVideoRenderer) {
        link = LinkedChannel(connection)
        self.renderer = renderer
    }

    func start() {
        queue.async { [self] in
            link.onClose = { [weak self] reason in
                self?.heartbeat?.cancel()
                self?.heartbeat = nil
                DispatchQueue.main.async { [weak self] in self?.onClose?(reason) }
            }
            link.onMessage = { [weak self] in self?.receive($0) }
            link.onFrame = { [weak self] in self?.render($0) }
            link.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self, !backgroundParked else { return }
                link.send(.init(.alive))
            }
            heartbeat = timer
            timer.resume()
        }
    }

    func send(_ message: LinkedMessage) {
        queue.async { [self] in link.send(message) }
    }

    func awaitFreshFrame(command: LinkedMessage? = nil) {
        queue.async { [self] in
            playback = .waiting
            backgroundParked = false
            if let command { link.send(command) }
        }
    }

    func pause(background: Bool, command: LinkedMessage? = nil) {
        queue.async { [self] in
            playback = .paused
            backgroundParked = background
            if let command { link.send(command) }
        }
    }

    func close() {
        queue.async { [self] in
            link.onClose = nil
            link.close()
            heartbeat?.cancel()
            heartbeat = nil
            renderer.flush(removingDisplayedImage: true)
        }
    }

    private func receive(_ message: LinkedMessage) {
        if message.kind == .ready, playback != .paused {
            needsFirstFrame = true
            playback = .playing
            decoder = LinkedDecoder()
            lastFrame = nil
            if renderer.status == .failed { renderer.flush(removingDisplayedImage: true) }
        }
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }

    private func render(_ bytes: Data) {
        guard playback == .playing else { link.send(.init(.frameAck)); return }
        let started = ProcessInfo.processInfo.systemUptime
        guard renderer.status != .failed, let sample = decoder.sample(from: bytes) else {
            link.close("Video playback interrupted. Resume sharing to try again.")
            return
        }
        renderer.enqueue(sample)
        link.send(.init(.frameAck))
        let now = ProcessInfo.processInfo.systemUptime
        if let lastFrame, started - lastFrame >= 0.25, now - lastLog >= 1 {
            lastLog = now
            log.notice("Desktop frame gap \(Int((started - lastFrame) * 1000)) ms, enqueue \(Int((now - started) * 1000)) ms")
        }
        lastFrame = started
        if needsFirstFrame {
            needsFirstFrame = false
            DispatchQueue.main.async { [weak self] in self?.onFirstFrame?() }
        }
    }
}
