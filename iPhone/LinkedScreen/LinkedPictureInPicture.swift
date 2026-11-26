import AVKit
import UIKit
import os

final class LinkedPictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
                                    AVPictureInPictureSampleBufferPlaybackDelegate {
    enum State { case idle, starting, active, restoring }

    private weak var client: LinkedClient?
    private var controller: AVPictureInPictureController!
    private let log = Logger(subsystem: "cn.zhaodk.glidecue", category: "LinkedPiP")
    private var observation: NSKeyValueObservation?
    private var startDeadline: DispatchWorkItem?
    private var transitionTask: UIBackgroundTaskIdentifier = .invalid
    private var restoration: ((Bool) -> Void)?
    private var restoreDeadline: DispatchWorkItem?
    private var explicitStart = false
    private var audioActive = false
    private var paused = false
    private weak var visibleSource: UIView?
    private var pipSource: UIView?
    private var returnWorkspace: LinkedClient.Workspace?

    init?(client: LinkedClient) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.client = client
        super.init()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: client.video, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.client?.pipPossible = self.controller.isPictureInPicturePossible
            }
        }
    }

    func configure(automatic: Bool, available: Bool) {
        controller.canStartPictureInPictureAutomaticallyFromInline = automatic && available
        if available && (automatic || explicitStart) { activateAudio() }
        else if client?.pipState == .idle { deactivateAudio() }
    }

    private func activateAudio() {
        guard !audioActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            audioActive = true
        } catch {
            log.error("Could not activate audio session for picture in picture")
        }
    }

    private func deactivateAudio() {
        guard audioActive else { return }
        audioActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func start() {
        guard let client, client.pipSupportedByMac, client.live, client.pipState == .idle,
              client.workspacePresented, controller.isPictureInPicturePossible else { return }
        explicitStart = true
        activateAudio()
        prepare()
        controller.startPictureInPicture()
    }

    func prepareForBackground() -> Bool {
        guard let client else { return false }
        if client.pipState == .idle {
            guard controller.canStartPictureInPictureAutomaticallyFromInline,
                  controller.isPictureInPicturePossible else { return false }
            prepare()
        }
        if client.pipState == .starting && transitionTask == .invalid {
            // Keep the transition alive long enough to park the original session if
            // system settings or another active player prevent automatic PiP.
            transitionTask = UIApplication.shared.beginBackgroundTask(withName: "Linked Screen PiP transition") { [weak self] in
                self?.failStart(showError: false)
            }
        }
        return client.pipState != .idle
    }

    private func finishStartTransition() {
        startDeadline?.cancel()
        startDeadline = nil
        if transitionTask != .invalid {
            UIApplication.shared.endBackgroundTask(transitionTask)
            transitionTask = .invalid
        }
    }

    private func prepare() {
        guard let client, client.live, client.pipSupportedByMac, client.pipState == .idle,
              let workspace = client.workspace else { return }
        returnWorkspace = workspace
        pipSource = visibleSource
        client.beginViewingOnly()
        client.pipState = .starting
        let deadline = DispatchWorkItem { [weak self] in self?.failStart() }
        startDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: deadline)
    }

    func foregrounded() {
        if client?.pipState == .starting, !explicitStart, !controller.isPictureInPictureActive {
            failStart(showError: false)
        }
    }

    private func failStart(showError: Bool = true) {
        guard let client, client.pipState == .starting else { return }
        explicitStart = false
        client.pipState = .idle
        returnWorkspace = nil
        pipSource = nil
        if showError && client.sceneIsActive { client.pipError = true }
        if client.sceneInBackground {
            deactivateAudio()
            client.fallbackFromPictureInPicture()
        }
        else {
            client.resumeInteractiveVideo()
            if !controller.canStartPictureInPictureAutomaticallyFromInline { deactivateAudio() }
        }
        finishStartTransition()
    }

    func restore() {
        guard let client, client.pipState == .active, controller.isPictureInPictureActive,
              let returnWorkspace else { return }
        client.pipState = .restoring
        client.showPictureInPictureWorkspace?(returnWorkspace)
        controller.stopPictureInPicture()
    }

    func sourceVisible(_ source: UIView) {
        visibleSource = source
        restoredCanvasVisible()
    }

    private func restoredCanvasVisible() {
        guard let restoration else { return }
        self.restoration = nil
        restoreDeadline?.cancel()
        restoration(true)
    }

    func reset() {
        finishStartTransition()
        restoreDeadline?.cancel()
        restoration?(false)
        restoration = nil
        explicitStart = false
        paused = false
        returnWorkspace = nil
        pipSource = nil
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        deactivateAudio()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        prepare()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard let client, client.running, client.pipState == .starting else {
            controller.stopPictureInPicture()
            return
        }
        finishStartTransition()
        client.pipState = .active
        if explicitStart { client.minimizeForPictureInPicture?() }
        explicitStart = false
        log.info("Picture in picture started")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        log.error("Picture in picture did not start: \(error.localizedDescription, privacy: .public)")
        failStart()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard let client, client.running, let returnWorkspace else { completionHandler(false); return }
        restoration?(false)
        restoration = completionHandler
        client.pipState = .restoring
        let deadline = DispatchWorkItem { [weak self] in
            self?.restoration?(false)
            self?.restoration = nil
        }
        restoreDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
        client.showPictureInPictureWorkspace?(returnWorkspace)
        if visibleSource?.window != nil, client.workspace == returnWorkspace { restoredCanvasVisible() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard let client, client.pipState != .idle else { return }
        let restoring = client.pipState == .restoring
        client.pipState = .idle
        paused = false
        returnWorkspace = nil
        pipSource = nil
        controller.invalidatePlaybackState()
        if restoring || (client.sceneIsActive && client.workspacePresented) {
            client.resumeInteractiveVideo()
        } else {
            client.end()
        }
        if !controller.canStartPictureInPictureAutomaticallyFromInline { deactivateAudio() }
        log.info("Picture in picture stopped")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard client?.pipState == .active, paused != !playing else { return }
        paused = !playing
        client?.setPictureInPicturePaused(paused)
        controller.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        client?.live == true ? .init(start: .zero, duration: .positiveInfinity) : .invalid
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { paused }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
