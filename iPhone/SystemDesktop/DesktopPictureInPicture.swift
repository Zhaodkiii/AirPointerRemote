import AVKit
import SwiftUI
import rootshellVNC

@MainActor
@Observable
final class DesktopPictureInPicture: NSObject, @MainActor AVPictureInPictureControllerDelegate,
                                     @MainActor AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var possible = false
    private(set) var active = false
    var failed = false
    private var stopSession: (() -> Void)?
    private var isReady: (() -> Bool)?
    private var pausePresentation: ((Bool) -> Void)?
    private var player: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?
    private var transition: Task<Void, Never>?
    private var transitionAssertion: UIBackgroundTaskIdentifier = .invalid
    private var paused = false
    private var restoring = false
    private var background = false
    private var audioActive = false

    func attach(to desktop: HighPerformanceDesktop, automatic: Bool) {
        let layer = desktop.session.videoBandRenderer.containerLayer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first
        attach(layer: layer, automatic: automatic, ready: { [weak desktop] in desktop?.ready == true },
               pause: { [weak desktop] in desktop?.session.suspendsDisplayPresentation = $0 },
               stop: { [weak desktop] in desktop?.stop() })
    }

    func attach(layer: AVSampleBufferDisplayLayer?, automatic: Bool, ready: @escaping () -> Bool,
                pause: @escaping (Bool) -> Void, stop: @escaping () -> Void) {
        stopSession = stop
        isReady = ready
        pausePresentation = pause
        guard player == nil, AVPictureInPictureController.isPictureInPictureSupported(), let layer else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let player = AVPictureInPictureController(contentSource: source)
        self.player = player
        player.delegate = self
        player.requiresLinearPlayback = true
        player.canStartPictureInPictureAutomaticallyFromInline = automatic
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
            audioActive = true
        } catch { failed = true }
        observation = player.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard self?.player === player else { return }
                self?.possible = player.isPictureInPicturePossible
            }
        }
    }

    func setAutomatic(_ enabled: Bool) {
        player?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func start() {
        guard let player, player.isPictureInPicturePossible else { return }
        player.startPictureInPicture()
    }

    func enteredBackground() {
        background = true
        guard !active else { return }
        // AVKit may deliver didStart after the scene has entered the background.
        finishTransition()
        transitionAssertion = UIApplication.shared.beginBackgroundTask(withName: "Desktop PiP transition") { [weak self] in
            guard let self else { return }
            if self.background && !self.active { self.stopSession?() }
            self.finishTransition()
        }
        transition = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, background, !active else { return }
            stopSession?()
        }
    }

    private func finishTransition() {
        transition?.cancel()
        transition = nil
        if transitionAssertion != .invalid {
            UIApplication.shared.endBackgroundTask(transitionAssertion)
            transitionAssertion = .invalid
        }
    }

    func foregrounded() {
        background = false
        finishTransition()
    }

    func reset() {
        finishTransition()
        observation = nil
        player?.delegate = nil
        player?.canStartPictureInPictureAutomaticallyFromInline = false
        if player?.isPictureInPictureActive == true { player?.stopPictureInPicture() }
        player?.contentSource = nil
        player = nil
        stopSession = nil
        isReady = nil
        pausePresentation = nil
        active = false
        possible = false
        restoring = false
        background = false
        paused = false
        failed = false
        if audioActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioActive = false
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === player else { return }
        finishTransition()
        active = true
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        guard controller === player else { return }
        if background { stopSession?() } else { failed = true }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        restoring = isReady?() == true
        done(restoring) // The full-screen desktop stays mounted during PiP.
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === player else { return }
        active = false
        if paused {
            paused = false
            pausePresentation?(false)
        }
        if background && !restoring { stopSession?() }
        restoring = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard controller === player else { return }
        paused = !playing
        pausePresentation?(paused)
        controller.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        .init(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { paused }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize size: CMVideoDimensions) {}
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime,
                                   completion completionHandler: @escaping () -> Void) { completionHandler() }
}
