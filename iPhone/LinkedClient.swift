import AVFoundation
import Network
import UIKit

final class LinkedClient: ObservableObject {
    @Published private(set) var status = "Connect to your Mac, then start sharing."
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
    // Resume only after a fresh authenticated Bluetooth connection to the same Mac.
    @Published private(set) var resumeMac: UUID?
    private var target: UUID?
    private var pendingKeyboardClick: (id: UUID, time: TimeInterval)?
    private var decoder = LinkedDecoder()
    let video = AVSampleBufferDisplayLayer()
    private weak var phone: PhoneConnection?
    private var channel: LinkedChannel?
    private var browser: NWBrowser?
    private var timeout: Timer?
    private var deadline = Date()
    private var displayName = "Mac display"
    private var uiActive = true
    private var pausedAt: TimeInterval?
    private var waitingForResumeFrame = false
    @Published private(set) var resuming = false
    @Published private(set) var canRetrySharing = false

    func start(_ phone: PhoneConnection) {
        guard !running, let offer = phone.beginLinkedScreen() else { return }
        resumeMac = nil
        canRetrySharing = false
        self.phone = phone
        sessionMac = phone.connectedMacID
        running = true
        status = "Finding your Mac on the local network…"
        deadline = Date().addingTimeInterval(30)
        let browser = NWBrowser(for: .bonjour(type: LinkedOffer.service, domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            if case .waiting(let error) = state { self.status = "Check Local Network access and Wi-Fi. " + error.localizedDescription }
            if case .failed(let error) = state { self.end(error.localizedDescription) }
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
        timeout = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard pausedAt == nil else { return }
            if live { channel?.send(.init(.alive)) }
            guard Date() > deadline else { return }
            interrupted(live ? "Mac stopped responding. Start sharing again." : "Timed out. Check both apps, Local Network access and Wi-Fi, then retry.")
        }
    }

    private func connect(_ connection: NWConnection) {
        let link = LinkedChannel(connection)
        channel = link
        link.onClose = { [weak self] reason in self?.interrupted(reason) }
        link.onMessage = { [weak self] in self?.receive($0) }
        link.onFrame = { [weak self] bytes in
            guard let self else { return }
            if pausedAt != nil || waitingForResumeFrame {
                channel?.send(.init(.frameAck))
                return
            }
            let renderer = video.sampleBufferRenderer
            if resuming {
                // iOS can revoke the video decoder when the app backgrounds.
                // The Mac sends an independent keyframe after its ready message.
                renderer.flush(removingDisplayedImage: true)
                decoder = LinkedDecoder()
                pendingKeyboardClick = nil
            }
            guard (resuming || renderer.status != .failed), let sample = decoder.sample(from: bytes) else {
                end("Video playback interrupted. Resume sharing to try again.", keepDraft: true)
                return
            }
            renderer.enqueue(sample)
            if !live { live = true }
            if resuming { resuming = false }
            deadline = Date().addingTimeInterval(5)
            channel?.send(.init(.frameAck))
        }
        link.start()
    }

    private func receive(_ message: LinkedMessage) {
        switch message.kind {
        case .waiting:
            deadline = Date().addingTimeInterval(95)
            status = "Choose the display to share on your Mac."
        case .ready:
            supportsGestures = message.supportsGestures == true
            guard pausedAt == nil else { return }
            waitingForResumeFrame = false
            if !resuming { phone?.linkedCanSuspend = message.backgroundResume == true }
            if awake { channel?.send(.init(.keepAwake, x: 1)) }
            guard message.x > 0, message.y > 0 else { end("Invalid display size."); return }
            size = CGSize(width: message.x, height: message.y)
            displayName = message.text ?? "Mac display"
            status = displayName
            deadline = Date().addingTimeInterval(12)
        case .alive:
            guard pausedAt == nil, !resuming else { return }
            deadline = Date().addingTimeInterval(5)
            let allowed = message.x == 1
            if canPoint != allowed { canPoint = allowed }
        case .focus:
            guard pausedAt == nil, !resuming else { return }
            supportsEditing = message.composerVersion == 1
            focus = message.token
            if draft.isEmpty && selectionID == nil {
                target = focus
            } else if target != focus {
                editorHint = "Focus changed. Confirm the new Mac field before inserting."
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
                      let text = message.text else { editorHint = "Select text on the Mac, then try again."; return }
                target = focus
                selectionID = id
                draft = text
                richEditor.attributedText = MacDraftEditor.attributed(text, styles: message.styles ?? [])
                richEditor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                editorHint = "Editing selected text"
                return
            }
            if message.kind == .inserted { cancelDraft(); status = "Text sent to the selected Mac field." }
            else { editorHint = "Edit rejected. Check the Mac field and selection." }
        case .stop:
            let reason = message.text ?? "Sharing ended."
            if message.x == 1 { interrupted(reason) } else { end(reason, keepDraft: resuming || pausedAt != nil) }
        default: break
        }
    }

    func sceneChanged(active: Bool, background: Bool) {
        uiActive = active
        if !active { pendingKeyboardClick = nil; releaseLinkedButton() }

        if background {
            guard running, pausedAt == nil else { return }
            guard (live || resuming), phone?.linkedCanSuspend == true else {
                end("Sharing paused. Resume when you’re ready.", keepDraft: true)
                return
            }
            pausedAt = ProcessInfo.processInfo.systemUptime
            waitingForResumeFrame = true
            resuming = true
            live = false
            canPoint = false
            focus = nil
            target = nil
            selectionID = nil
            richEditor.resignFirstResponder()
            status = "Screen sharing paused."
        } else if active, let pausedAt {
            self.pausedAt = nil
            guard ProcessInfo.processInfo.systemUptime - pausedAt < PhoneProtocol.LinkedLifecycle.grace else {
                end("Sharing paused too long. Choose a display to share again.", keepDraft: true)
                return
            }
            deadline = Date().addingTimeInterval(8)
            status = "Restoring the shared display…"
            if submitting != nil {
                submitting = nil
                readingSelection = false
                editorHint = "Check the Mac before submitting this draft again."
            } else if !draft.isEmpty {
                editorHint = "Confirm the Mac field before inserting your draft."
            }
        }
    }

    func interrupted(_ reason: String) {
        guard running else { return }
        let id = sessionMac
        let shouldRetryAfterWake = live && !resuming && pausedAt == nil
        end(reason, keepDraft: true)
        if shouldRetryAfterWake { resumeMac = id }
    }

    private var sessionMac: UUID?
    func connectionChanged(_ phone: PhoneConnection) {
        if !phone.connected {
            interrupted("Connection to the Mac was interrupted.")
        } else if let resumeMac, phone.connectedMacID == resumeMac, !phone.macPaused, uiActive {
            start(phone)
        }
    }

    func end(_ reason: String = "Sharing ended.", keepDraft: Bool = false) {
        resumeMac = nil
        sessionMac = nil
        canRetrySharing = keepDraft
        guard running else {
            if !keepDraft { cancelDraft() }
            return
        }
        pausedAt = nil
        waitingForResumeFrame = false
        resuming = false
        running = false; live = false
        status = submitting == nil ? reason : "Sharing ended. Check the Mac before inserting again."
        browser?.cancel(); browser = nil
        timeout?.invalidate(); timeout = nil
        channel?.onClose = nil; channel?.close(); channel = nil
        phone?.finishLinkedScreen(); phone = nil
        video.sampleBufferRenderer.flush(removingDisplayedImage: true)
        decoder = LinkedDecoder()
        pendingKeyboardClick = nil
        focus = nil; submitting = nil; canPoint = false
        if keepDraft && !draft.isEmpty {
            target = nil
            selectionID = nil
            readingSelection = false
            editorHint = "Confirm the Mac field before inserting your draft."
        } else { cancelDraft() }
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
        guard uiActive, live, canPoint else { return }
        if command.kind == .gesture && !supportsGestures { return }
        var message = command
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
        guard focus != nil else { return }
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
        channel?.send(command)
    }
    func insert(deleting: Bool = false) {
        if deleting {
            guard uiActive, let target, target == focus, selectionID != nil, submitting == nil, live, canPoint else { return }
        } else { guard canInsert else { return } }
        guard richEditor.markedTextRange == nil else { editorHint = "Finish composing the current word first."; return }
        let styles = deleting ? [] : MacDraftEditor.styles(in: richEditor.attributedText)
        guard styles.count <= 512 else { editorHint = "Too many formatting changes. Split this edit."; return }
        guard supportsEditing || styles.isEmpty else { editorHint = "Update the Mac receiver for formatted text."; return }
        let id = UUID()
        var command = LinkedMessage(.insert, token: target, request: id, text: deleting ? "" : draft)
        command.styles = styles.isEmpty ? nil : styles
        command.selection = selectionID
        submitting = id
        channel?.send(command)
    }
}
