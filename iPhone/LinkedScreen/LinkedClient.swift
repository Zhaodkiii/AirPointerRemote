import AVFoundation
import Network
import UIKit

final class LinkedClient: ObservableObject {
    enum Workspace { case inline, linkedScreen }
    @Published private(set) var status = String(localized: "Connect to your Mac, then start sharing.")
    @Published private(set) var running = false
    @Published private(set) var live = false
    @Published private(set) var size = CGSize(width: 16, height: 9)
    @Published private(set) var focus: UUID?
    @Published var draft = ""
    let richEditor: UITextView = {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        return view
    }()
    @Published private(set) var supportsEditing = false
    @Published private(set) var selectionID: UUID?
    @Published var editorHint: String?
    private var readingSelection = false
    @Published var editing = false
    @Published private(set) var submitting: UUID?
    @Published private(set) var awake = UserDefaults.standard.bool(forKey: "linked.keepMacAwake")
    @Published private(set) var canPoint = false
    @Published private(set) var videoDelayed = false
    @Published private(set) var videoQuality: String?
    // Resume only after a fresh authenticated Bluetooth connection to the same Mac.
    @Published private(set) var resumeMac: UUID?
    private var target: UUID?
    private var pendingKeyboardClick: (id: UUID, time: TimeInterval)?
    let video = AVSampleBufferDisplayLayer()
    private weak var phone: PhoneConnection?
    @Published private(set) var diagnostics: VideoDiagnostics?
    private var videoEpoch: Int?
    private var controlStamp: Double?
    private var channel: LinkedVideoStream?
    private var browser: NWBrowser?
    private var timeout: Timer?
    private var deadline = Date()
    private(set) var displayName = String(localized: "Mac display")
    private var uiActive: Bool { sceneIsActive && workspacePresented && pipState == .idle }
    private(set) var sceneIsActive = true
    private(set) var sceneInBackground = false
    var workspace: Workspace?
    var workspacePresented: Bool { workspace != nil }
    @Published var directTouch = false
    @Published var fullScreen = false
    private(set) var viewport = LinkedViewport()
    @Published private(set) var previewZoomed = false
    @Published var previewFraction = 0.50
    var minimizeForPictureInPicture: (() -> Void)?
    var showPictureInPictureWorkspace: ((Workspace) -> Void)?
    @Published private(set) var pipSupportedByMac = false
    @Published var pipPossible = false
    @Published var pipState: LinkedPictureInPicture.State = .idle
    @Published var pipError = false
    lazy var pictureInPicture = LinkedPictureInPicture(client: self)

    func beginViewingOnly() {
        releaseLinkedButton()
        hideKeyboard()
        canPoint = false
        focus = nil
        target = nil
        selectionID = nil
        channel?.send(.init(.viewing, x: 1))
    }

    func resumeInteractiveVideo() {
        canPoint = false
        resuming = true
        deadline = Date().addingTimeInterval(8)
        channel?.awaitFreshFrame(command: .init(.viewing))
    }

    func setPictureInPicturePaused(_ paused: Bool) {
        if paused {
            resuming = false
            channel?.pause(background: false, command: .init(.viewing, x: 2))
        } else {
            resuming = true
            deadline = Date().addingTimeInterval(8)
            channel?.awaitFreshFrame(command: .init(.viewing, x: 1))
        }
    }

    func fallbackFromPictureInPicture() {
        phone?.setForeground(false)
        pauseForBackground()
    }
    private var pausedAt: TimeInterval?
    @Published private(set) var resuming = false
    @Published private(set) var canRetrySharing = false

    private var inlineRequest = false
    @Published private(set) var closedLidDesktop = false
    @Published private(set) var showCloseLidHint = false
    @Published private(set) var requiresOpenLid = false
    @Published private(set) var closedLidPowerWarning: String?
    private var closeLidHintTask: Task<Void, Never>?
    private var showDisplayHintOnNextFrame = false
    private weak var reconnectPhone: PhoneConnection?
    private var offer: LinkedOffer?
    private var transportResume = false
    private var transportDeadline: TimeInterval?
    var reconnectingTransport: Bool { transportDeadline != nil }
    private var retryTransport: Task<Void, Never>?

    func start(_ phone: PhoneConnection, inline: Bool = false, chooseDisplay: Bool = false) {
        guard !running, let offer = phone.beginLinkedScreen(inline: inline, chooseDisplay: chooseDisplay) else { return }
        resumeMac = nil
        reconnectPhone = nil
        canRetrySharing = false
        inlineRequest = inline
        self.phone = phone
        sessionMac = phone.connectedMacID
        running = true
        status = String(localized: "Finding your Mac on the local network…")
        deadline = Date().addingTimeInterval(30)
        self.offer = offer
        browse(offer)
        timeout = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard pausedAt == nil else { return }
            guard Date() > deadline else { return }
            interrupted(live ? String(localized: "Mac stopped responding. Start sharing again.") : String(localized: "Timed out. Check both apps, Local Network access and Wi-Fi, then retry."))
        }
    }

    private func browse(_ offer: LinkedOffer) {
        let browser = NWBrowser(for: .bonjour(type: LinkedOffer.service, domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            if case .waiting(let error) = state, self.transportDeadline == nil { self.status = String(localized: "Check Local Network access and Wi-Fi. ") + error.localizedDescription }
            if case .failed(let error) = state { self.interrupted(error.localizedDescription) }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint, name == offer.name {
                    self.browser = nil; browser.cancel()
                    self.connect(NWConnection(to: result.endpoint, using: offer.parameters))
                    return
                }
            }
        }
        browser.start(queue: .main)
    }

    private func reconnectTransport(using offer: LinkedOffer) {
        let now = ProcessInfo.processInfo.systemUptime
        if transportDeadline == nil {
            transportDeadline = now + 27
            resuming = true
            canPoint = false
            videoDelayed = false
            pendingKeyboardClick = nil
            focus = nil
            target = nil
            selectionID = nil
            if submitting != nil {
                submitting = nil
                readingSelection = false
                editorHint = String(localized: "Check the Mac before submitting this draft again.")
            }
            status = closedLidDesktop ? String(localized: "Reconnecting to Lid Desktop…") : String(localized: "Reconnecting to your Mac…")
            showCloseLidHint = false
        }
        guard let transportDeadline, now < transportDeadline else {
            end(String(localized: "Lid Desktop could not reconnect. Open the Mac lid and try sharing again."), keepDraft: true)
            return
        }
        channel?.close(keepLastFrame: true)
        channel = nil
        browser?.cancel()
        browser = nil
        retryTransport?.cancel()
        deadline = Date().addingTimeInterval(min(5, transportDeadline - now))
        retryTransport = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.running, self.transportDeadline != nil else { return }
            self.browse(offer)
        }
    }

    private func connect(_ connection: NWConnection) {
        guard let offer else { connection.cancel(); return }
        videoEpoch = nil
        controlStamp = nil
        diagnostics = nil
        let link = LinkedVideoStream(connection, offer: offer, renderer: video.sampleBufferRenderer)
        link.onDiagnostics = { [weak self, weak link] metrics in
            guard let self, let link, self.channel === link else { return }
            self.diagnostics = metrics
        }
        link.onVideoRecovery = { [weak self, weak link] in
            guard let self, let link, self.channel === link else { return }
            self.canPoint = false
            self.resuming = true
            self.deadline = Date().addingTimeInterval(15)
        }
        channel = link
        link.onClose = { [weak self, weak link] reason in
            guard let self, let link, channel === link else { return }
            interrupted(reason)
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, channel === link else { return }
            receive(message)
        }
        link.onFirstFrame = { [weak self, weak link] in
            guard let self, let link, channel === link, pausedAt == nil else { return }
            pendingKeyboardClick = nil
            if !live { live = true }
            if showDisplayHintOnNextFrame {
                showDisplayHintOnNextFrame = false
                showCloseLidHint = true
                closeLidHintTask?.cancel()
                closeLidHintTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.showCloseLidHint = false
                }
            }
            if resuming { resuming = false }
            transportDeadline = nil
            status = displayName
            deadline = Date().addingTimeInterval(transportResume ? 11 : 5)
        }
        link.start()
    }

    private func receive(_ message: LinkedMessage) {
        switch message.kind {
        case .waiting:
            deadline = Date().addingTimeInterval(95)
            status = message.closedLidDesktop == true
                ? String(localized: "Preparing Lid Desktop on your Mac…")
                : String(localized: "Choose the display to share on your Mac.")
        case .ready:
            if videoEpoch != message.videoEpoch { canPoint = false }
            videoEpoch = message.videoEpoch
            let oldLidDisplay = closedLidDesktop
            closedLidDesktop = message.closedLidDesktop == true
            transportResume = message.transportResume == true
            requiresOpenLid = message.requiresOpenLid == true
            supportsGestures = message.supportsGestures == true
            pipSupportedByMac = message.pictureInPicture == true
            guard pausedAt == nil else { return }
            phone?.linkedCanSuspend = message.backgroundResume == true
            if awake { channel?.send(.init(.keepAwake, x: 1)) }
            guard message.x > 0, message.y > 0 else { end(String(localized: "Invalid display size.")); return }
            let nextSize = CGSize(width: message.x, height: message.y)
            let nextName = message.text.flatMap { $0 == "Mac display" ? nil : $0 } ?? String(localized: "Mac display")
            let changedDisplay = nextName != displayName || oldLidDisplay != closedLidDesktop
            if !live || changedDisplay {
                showDisplayHintOnNextFrame = closedLidDesktop || requiresOpenLid
            }
            if live && changedDisplay {
                closeLidHintTask?.cancel()
                showCloseLidHint = false
                canPoint = false
                resuming = true
                focus = nil
                target = nil
                selectionID = nil
                pendingKeyboardClick = nil
                hideKeyboard()
            }
            if nextSize != size || changedDisplay { fitPreview() }
            size = nextSize
            displayName = nextName
            status = displayName
            let remaining = transportDeadline.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) } ?? 12
            deadline = Date().addingTimeInterval(min(12, remaining))
        case .alive:
            controlStamp = message.controlStamp
            guard pausedAt == nil, !resuming else { return }
            deadline = Date().addingTimeInterval(transportResume ? 11 : 5)
            let delayed = message.videoDelayed == true && pipState == .idle
            if videoDelayed != delayed { videoDelayed = delayed }
            let quality = message.videoBitrate.flatMap { bitrate in
                message.videoFPS.map { fps in
                    String(format: String(localized: "%.1f Mbps · up to %d FPS"), Double(bitrate) / 1_000_000, fps)
                }
            }
            if videoQuality != quality { videoQuality = quality }
            if closedLidPowerWarning != message.closedLidPowerWarning {
                closedLidPowerWarning = message.closedLidPowerWarning
            }
            let allowed = message.x == 1 && !delayed && pipState == .idle
            if canPoint != allowed { canPoint = allowed }
        case .focus:
            guard pausedAt == nil, !resuming else { return }
            supportsEditing = message.composerVersion == 1
            focus = message.token
            if draft.isEmpty && selectionID == nil {
                target = focus
            } else if target != focus {
                editorHint = String(localized: "Focus changed. Confirm the new Mac field before inserting.")
            }
            if focus == nil {
                // Focus can briefly clear while a user click moves between fields.
                closeComposer()
                return
            }
            if let click = pendingKeyboardClick, click.id == message.keyboardClick {
                pendingKeyboardClick = nil
                if uiActive, live, canPoint,
                   ProcessInfo.processInfo.systemUptime - click.time < 1 {
                    openKeyboard()
                }
            }
        case .inserted, .rejected:
            guard let request = submitting, request == message.request else { return }
            submitting = nil
            if readingSelection {
                readingSelection = false
                guard message.kind == .inserted, message.token == focus, let id = message.selection,
                      let text = message.text else { editorHint = String(localized: "Select text on the Mac, then try again."); return }
                target = focus
                selectionID = id
                draft = text
                richEditor.attributedText = MacDraftEditor.attributed(text, styles: message.styles ?? [])
                richEditor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                editorHint = String(localized: "Editing selected text")
                return
            }
            if message.kind == .inserted { cancelDraft(); status = String(localized: "Text sent to the selected Mac field.") }
            else { editorHint = String(localized: "Edit rejected. Check the Mac field and selection.") }
        case .stop:
            let reason = message.text ?? "Sharing ended."
            if message.x == 1 || message.x == 2 {
                interrupted(reason)
            } else {
                end(reason, keepDraft: resuming || pausedAt != nil)
            }
        default: break
        }
    }

    func sceneChanged(active: Bool, background: Bool, controller: RemoteController) {
        sceneIsActive = active
        sceneInBackground = background
        if !active {
            pendingKeyboardClick = nil
            releaseLinkedButton()
        }
        let viewing = background && running && (pictureInPicture?.prepareForBackground() == true)
        if active {
            pictureInPicture?.foregrounded()
            resumeFromBackground()
        }
        controller.setForeground(active, inBackground: background, viewing: viewing)
        if background && !viewing { pauseForBackground() }
    }

    private func pauseForBackground() {
        guard running, pausedAt == nil else { return }
        guard (live || resuming), phone?.linkedCanSuspend == true else {
            end(String(localized: "Sharing paused. Resume when you’re ready."), keepDraft: true)
            return
        }
        pausedAt = ProcessInfo.processInfo.systemUptime
        channel?.pause(background: true)
        resuming = true
        live = false
        canPoint = false
        focus = nil
        target = nil
        selectionID = nil
        richEditor.resignFirstResponder()
        status = String(localized: "Screen sharing paused.")
    }

    private func resumeFromBackground() {
        guard let pausedAt else { return }
        self.pausedAt = nil
        guard ProcessInfo.processInfo.systemUptime - pausedAt < PhoneProtocol.LinkedLifecycle.grace else {
            end(String(localized: "Sharing paused too long. Choose a display to share again."), keepDraft: true)
            return
        }
        deadline = Date().addingTimeInterval(8)
        channel?.awaitFreshFrame()
        status = String(localized: "Restoring the shared display…")
        if submitting != nil {
            submitting = nil
            readingSelection = false
            editorHint = String(localized: "Check the Mac before submitting this draft again.")
        } else if !draft.isEmpty {
            editorHint = String(localized: "Confirm the Mac field before inserting your draft.")
        }
    }

    func interrupted(_ reason: String) {
        guard running else { return }
        let id = sessionMac
        let previousPhone = phone
        if transportResume, live || transportDeadline != nil, pausedAt == nil, let offer {
            reconnectTransport(using: offer)
            return
        }
        let shouldRetryAfterWake = live && !resuming && pausedAt == nil && pipState == .idle
        let reconnectLid = closedLidDesktop && shouldRetryAfterWake
        end(reconnectLid ? String(localized: "Reconnecting to Lid Desktop…") : reason,
            keepDraft: true, preserveClosedLidSession: reconnectLid)
        if shouldRetryAfterWake { resumeMac = id }
        if reconnectLid, let id {
            reconnectPhone = previousPhone
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak previousPhone] in
                guard let self, let previousPhone, resumeMac == id else { return }
                connectionChanged(previousPhone)
            }
        }
    }

    private var sessionMac: UUID?
    func connectionChanged(_ phone: PhoneConnection) {
        if !phone.connected {
            if transportResume && (live || transportDeadline != nil) { return }
            interrupted(String(localized: "Connection to the Mac was interrupted."))
        } else if transportResume, running, phone.connectedMacID == sessionMac {
            phone.rejoinLinkedScreen()
        } else if let resumeMac, phone.connectedMacID == resumeMac, !phone.macPaused, uiActive {
            start(phone, inline: inlineRequest)
        }
    }

    func end(_ reason: String = String(localized: "Sharing ended."), keepDraft: Bool = false,
             preserveClosedLidSession: Bool = false) {
        reconnectPhone?.finishLinkedScreen()
        reconnectPhone = nil
        resumeMac = nil
        sessionMac = nil
        canRetrySharing = keepDraft
        guard running else {
            if !keepDraft { cancelDraft() }
            return
        }
        let shouldSendStop = transportResume && !preserveClosedLidSession
        transportResume = false
        transportDeadline = nil
        retryTransport?.cancel()
        retryTransport = nil
        offer = nil
        closedLidDesktop = false
        requiresOpenLid = false
        closeLidHintTask?.cancel()
        showCloseLidHint = false
        showDisplayHintOnNextFrame = false
        closedLidPowerWarning = nil
        pipState = .idle
        directTouch = false
        fullScreen = false
        fitPreview()
        previewFraction = 0.50
        pipSupportedByMac = false
        pictureInPicture?.reset()
        pausedAt = nil
        resuming = false
        running = false; live = false
        status = submitting == nil ? Bundle.main.localizedString(forKey: reason, value: reason, table: nil) : String(localized: "Sharing ended. Check the Mac before inserting again.")
        browser?.cancel(); browser = nil
        timeout?.invalidate(); timeout = nil
        channel?.close(notifyMac: shouldSendStop); channel = nil
        phone?.finishLinkedScreen(interrupted: preserveClosedLidSession); phone = nil
        pendingKeyboardClick = nil
        focus = nil; submitting = nil; canPoint = false
        videoDelayed = false
        diagnostics = nil
        videoQuality = nil
        if keepDraft && !draft.isEmpty {
            target = nil
            selectionID = nil
            readingSelection = false
            editorHint = String(localized: "Confirm the Mac field before inserting your draft.")
        } else { cancelDraft() }
    }

    func updateViewport(_ change: (inout LinkedViewport) -> Void) {
        change(&viewport)
        let zoomed = viewport.zoom > 1
        if previewZoomed != zoomed { previewZoomed = zoomed }
    }

    func fitPreview() {
        updateViewport { $0 = LinkedViewport() }
    }

    func releaseLinkedButton(userClick: Bool = false) {
        var message = LinkedMessage(.dragEnd)
        if userClick && uiActive && live && canPoint { markKeyboardClick(&message) }
        channel?.send(message)
    }

    private var supportsGestures = false

    private func markKeyboardClick(_ message: inout LinkedMessage) {
        let id = UUID()
        pendingKeyboardClick = (id, ProcessInfo.processInfo.systemUptime)
        message.keyboardClick = id
    }

    func control(_ command: LinkedMessage) {
        guard uiActive, live, canPoint || (videoDelayed && command.kind == .relative) else { return }
        if command.kind == .gesture && !supportsGestures { return }
        var message = command
        message.videoEpoch = videoEpoch
        message.controlStamp = controlStamp
        switch message.kind {
        case .click, .doubleClick, .currentClick, .currentDouble: markKeyboardClick(&message)
        case .currentDown, .dragStart, .rightClick, .currentRight: pendingKeyboardClick = nil
        default: break
        }
        channel?.send(message)
    }
    func setAwake(_ enabled: Bool) {
        awake = enabled
        UserDefaults.standard.set(enabled, forKey: "linked.keepMacAwake")
        if live { channel?.send(.init(.keepAwake, x: enabled ? 1 : 0)) }
    }
    func openKeyboard() {
        guard uiActive, focus != nil else { return }
        if draft.isEmpty && selectionID == nil { target = focus }
        editing = true
    }

    func useNewField() {
        selectionID = nil
        target = focus
        editorHint = nil
    }

    func hideKeyboard() {
        pendingKeyboardClick = nil
        closeComposer()
    }

    private func closeComposer() {
        richEditor.resignFirstResponder()
        editing = false
    }
    func cancelDraft() {
        hideKeyboard()
        draft = ""; target = nil; selectionID = nil; readingSelection = false; editorHint = nil
        richEditor.attributedText = nil
        richEditor.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
    }
    var canInsert: Bool { uiActive && live && canPoint && focus != nil && focus == target && !draft.isEmpty && draft.utf8.count <= 16384 && submitting == nil }
    var needsTarget: Bool { focus != nil && target != focus }
    func loadSelection() {
        guard uiActive, supportsEditing, live, canPoint, let focus, submitting == nil else { return }
        let id = UUID()
        readingSelection = true
        submitting = id
        var command = LinkedMessage(.insert, token: focus, request: id, text: "")
        command.readSelection = true
        command.videoEpoch = videoEpoch
        command.controlStamp = controlStamp
        channel?.send(command)
    }
    func insert(deleting: Bool = false) {
        if deleting {
            guard uiActive, let target, target == focus, selectionID != nil, submitting == nil, live, canPoint else { return }
        } else { guard canInsert else { return } }
        guard richEditor.markedTextRange == nil else { editorHint = String(localized: "Finish composing the current word first."); return }
        let styles = deleting ? [] : MacDraftEditor.styles(in: richEditor.attributedText)
        guard styles.count <= 512 else { editorHint = String(localized: "Too many formatting changes. Split this edit."); return }
        guard supportsEditing || styles.isEmpty else { editorHint = String(localized: "Update the Mac receiver for formatted text."); return }
        let id = UUID()
        var command = LinkedMessage(.insert, token: target, request: id, text: deleting ? "" : draft)
        command.styles = styles.isEmpty ? nil : styles
        command.selection = selectionID
        submitting = id
        command.videoEpoch = videoEpoch
        command.controlStamp = controlStamp
        channel?.send(command)
    }
}
