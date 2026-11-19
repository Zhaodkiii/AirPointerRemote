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
    @Published var editing = false
    @Published private(set) var submitting: UUID?
    @Published private(set) var awake = UserDefaults.standard.bool(forKey: "linked.keepMacAwake")
    @Published private(set) var canPoint = false
    // Resume only after a fresh authenticated Bluetooth connection to the same Mac.
    @Published private(set) var resumeMac: UUID?
    private var target: UUID?
    private var decoder = LinkedDecoder()
    let video = AVSampleBufferDisplayLayer()
    private weak var phone: PhoneConnection?
    private var channel: LinkedChannel?
    private var browser: NWBrowser?
    private var timeout: Timer?
    private var deadline = Date()
    private var displayName = "Mac display"

    func start(_ phone: PhoneConnection) {
        guard !running, let offer = phone.beginLinkedScreen() else { return }
        resumeMac = nil
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
            guard let self, let sample = decoder.sample(from: bytes), video.sampleBufferRenderer.status != .failed else {
                self?.end("Video playback interrupted. Start sharing again."); return
            }
            video.sampleBufferRenderer.enqueue(sample)
            live = true
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
            if awake { channel?.send(.init(.keepAwake, x: 1)) }
            guard message.x > 0, message.y > 0 else { end("Invalid display size."); return }
            size = CGSize(width: message.x, height: message.y)
            displayName = message.text ?? "Mac display"
            status = displayName
            deadline = Date().addingTimeInterval(12)
        case .alive:
            deadline = Date().addingTimeInterval(5)
            canPoint = message.x == 1
        case .focus:
            focus = message.token
            if draft.isEmpty {
                target = focus
                editing = focus != nil
            } else if target != focus {
                status = "Focus changed. Choose a field before inserting your draft."
            }
        case .inserted, .rejected:
            guard let request = submitting, request == message.request else { return }
            submitting = nil
            if message.kind == .inserted { cancelDraft(); status = "Text sent to the selected Mac field." }
            else { status = "Text could not be inserted. Check the selected Mac field." }
        case .stop:
            let reason = message.text ?? "Sharing ended."
            if message.x == 1 { interrupted(reason) } else { end(reason) }
        default: break
        }
    }

    func interrupted(_ reason: String) {
        guard running else { return }
        let id = sessionMac
        let activeSession = live
        end(reason)
        if activeSession { resumeMac = id }
    }

    private var sessionMac: UUID?
    func connectionChanged(_ phone: PhoneConnection) {
        if !phone.connected {
            interrupted("Mac disconnected. Waiting for it to wake…")
        } else if let resumeMac, phone.connectedMacID == resumeMac, !phone.macPaused {
            start(phone)
        }
    }

    func end(_ reason: String = "Sharing ended.") {
        resumeMac = nil
        sessionMac = nil
        guard running else { return }
        running = false; live = false
        status = submitting == nil ? reason : "Sharing ended. Check the Mac before inserting again."
        browser?.cancel(); browser = nil
        timeout?.invalidate(); timeout = nil
        channel?.onClose = nil; channel?.close(); channel = nil
        phone?.finishLinkedScreen(); phone = nil
        video.sampleBufferRenderer.flush(removingDisplayedImage: true)
        decoder = LinkedDecoder()
        focus = nil; submitting = nil; canPoint = false
        cancelDraft()
    }

    func control(_ message: LinkedMessage) {
        guard live, canPoint else { return }
        channel?.send(message)
    }
    func setAwake(_ enabled: Bool) {
        awake = enabled
        UserDefaults.standard.set(enabled, forKey: "linked.keepMacAwake")
        if live { channel?.send(.init(.keepAwake, x: enabled ? 1 : 0)) }
    }
    func openKeyboard() { target = focus; editing = true }
    func cancelDraft() { draft = ""; editing = false; target = nil }
    var canInsert: Bool { live && canPoint && focus != nil && focus == target && !draft.isEmpty && draft.utf8.count <= 16384 && submitting == nil }
    var needsTarget: Bool { focus != nil && target != focus }
    func insert() {
        guard canInsert else { return }
        let id = UUID()
        submitting = id
        channel?.send(.init(.insert, token: target, request: id, text: draft))
    }
}
