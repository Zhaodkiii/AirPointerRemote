import AppKit
import ServiceManagement

final class ClosedLidDesktop: ObservableObject {
    static let shared = ClosedLidDesktop()
    private let preference = "closedLidDesktop.enabled"
    private let service = SMAppService.daemon(plistName: LidPowerService.plistName)
    private let brightness = BuiltInBrightness()
    private var screen: VirtualScreen?
    private weak var host: LinkedHost?
    private var peer: String?
    private var connection: NSXPCConnection?
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var reconnectTimer: Timer?
    private var preparation: UUID?
    private var activity: NSObjectProtocol?
    private var endingPower = false
    private var requestedBuiltIn = false
    private var enteringLidForExistingShare = false

    @Published private(set) var enabled = false
    @Published private(set) var recordingAllowed = false
    @Published private(set) var pointerAllowed = false
    @Published private(set) var powerStatus: SMAppService.Status = .notRegistered
    @Published private(set) var supported = false
    @Published private(set) var message = ""
    @Published private(set) var sharing = false
    @Published private(set) var powerWarning: String?
    @Published private(set) var active = false
    @Published private(set) var lidClosed = false
    @Published private(set) var switchingDisplay = false
    @Published private(set) var sharingAnotherDisplay = false

    var canSwitchToLidDesktop: Bool {
        sharingAnotherDisplay && !active && !switchingDisplay && !endingPower &&
            supported && !lidClosed && recordingAllowed && powerStatus == .enabled
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: preference)
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.endForMacLock()
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.endForMacLock()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.active else { return }
            self.stop()
        })
    }

    private func endForMacLock() {
        if active { stop(reason: "Mac locked or went to sleep. Unlock it to share again.") }
    }

    func refresh() {
        let hasOtherShare = LinkedHost.sharing?.canSwitchToLidDisplay == true
        if sharingAnotherDisplay != hasOtherShare { sharingAnotherDisplay = hasOtherShare }
        let screenAccess = CGPreflightScreenCaptureAccess()
        if recordingAllowed != screenAccess { recordingAllowed = screenAccess }
        let pointerAccess = CGPreflightPostEventAccess()
        if pointerAllowed != pointerAccess { pointerAllowed = pointerAccess }
        let status = service.status
        if powerStatus != status { powerStatus = status }
        let lid = brightness.lidClosed
        if supported != (lid != nil) { supported = lid != nil }
        if let lid, lidClosed != lid {
            lidClosed = lid
            if lid { host?.lidDidClose() }
            else { switchWhenReady() }
        }
        brightness.update(enabled: active && activity != nil)
        if active && (status != .enabled || !screenAccess) {
            stopAfterFailure("Closed-lid sharing permissions changed. Check the Mac settings.")
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: preference)
        message = ""
        if enabled, LinkedHost.sharing != nil, !active {
            requestLidDesktop()
        } else if !enabled && active {
            requestBuiltInDisplay()
        }
    }

    func requestLidDesktop() {
        guard !active, !switchingDisplay, let host = LinkedHost.sharing,
              host.canSwitchToLidDisplay else { return }
        enteringLidForExistingShare = true
        switchingDisplay = true
        self.host = host
        message = String(localized: "Preparing Lid Desktop for the current share…")
        prepare(for: host, peer: host.peer) { [weak self, weak host] result in
            guard let self, let host, self.host === host, self.enteringLidForExistingShare else { return }
            switch result {
            case .failure(let error):
                self.stopAfterFailure(error.reason)
            case .success(let id):
                self.message = String(localized: "Switching the current share to Lid Desktop…")
                host.switchToLidDisplay(id) { [weak self, weak host] switched in
                    guard let self, let host, self.host === host, self.enteringLidForExistingShare else { return }
                    if switched {
                        self.enteringLidForExistingShare = false
                        self.switchingDisplay = false
                        self.firstFrame(for: host)
                    } else {
                        self.stopAfterFailure("Could not switch to Lid Desktop. Your original display is still shared.")
                    }
                }
            }
        }
    }

    private func stopAfterFailure(_ reason: String) {
        guard enteringLidForExistingShare else {
            stop(reason: reason)
            return
        }
        let current = host
        host = nil
        current?.cancelLidDisplayHandoff()
        release()
        message = Bundle.main.localizedString(forKey: reason, value: reason, table: nil)
    }

    func requestBuiltInDisplay() {
        guard active, !switchingDisplay else { return }
        requestedBuiltIn = true
        switchWhenReady()
    }

    private func switchWhenReady() {
        guard requestedBuiltIn, !switchingDisplay else { return }
        guard brightness.lidClosed == false else {
            message = String(localized: "Open the Mac lid to switch displays. Lid Desktop is still shared.")
            return
        }
        guard sharing, let host else {
            message = String(localized: "Waiting for iPhone before switching displays…")
            return
        }
        requestedBuiltIn = false
        switchingDisplay = true
        message = String(localized: "Switching to the built-in display…")
        host.switchToBuiltInDisplay { [weak self, weak host] success in
            guard let self, let host, self.host === host else { return }
            self.switchingDisplay = false
            if success {
                self.host = nil
                self.release()
                self.message = String(localized: "Your iPhone is now sharing the built-in display.")
            } else {
                self.message = String(localized: "Could not switch displays. Lid Desktop is still shared. Try again with the lid open.")
            }
        }
    }

    func setupPower() {
        message = ""
        switch service.status {
        case .enabled: break
        case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
        default:
            do {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                message = String(localized: "Could not register the power helper. Open AirPointer Remote from Applications.") + " " + error.localizedDescription
            }
        }
        refresh()
    }

    func removePowerHelper() {
        guard !active, !endingPower else { return }
        do {
            try service.unregister()
            setEnabled(false)
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    func prepare(for host: LinkedHost, peer: String, completion: @escaping (Result<CGDirectDisplayID, StringError>) -> Void) {
        refresh()
        guard supported else { completion(.failure(.init("Closed-lid desktop is unavailable on this Mac."))); return }
        guard recordingAllowed else { completion(.failure(.init("On the Mac, allow Screen Recording for Closed-Lid Desktop, then try again."))); return }
        guard powerStatus == .enabled else { completion(.failure(.init("On the Mac, approve the Closed-Lid Desktop power helper, then try again."))); return }
        if active {
            guard self.peer == peer, reconnectTimer != nil, let screen, activity != nil else {
                completion(.failure(.init("A closed-lid sharing session is already active.")))
                return
            }
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            self.host = host
            message = String(localized: "Reconnecting your iPhone…")
            completion(.success(screen.displayID))
            return
        }
        guard !endingPower else {
            completion(.failure(.init("Normal sleep is being restored. Try sharing again in a moment.")))
            return
        }
        guard !lidClosed else { completion(.failure(.init("Open the Mac lid before starting Closed-Lid Desktop."))); return }
        let existing = NSScreen.screens.contains {
            guard let id = ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayVendorNumber(id) == 0x4c44 && CGDisplayModelNumber(id) == 1 && CGDisplaySerialNumber(id) == 1
        }
        guard !existing else {
            completion(.failure(.init("Stop the separate Lid Desktop app before starting integrated sharing.")))
            return
        }
        guard let screen = VirtualScreen(forSharing: ()) else {
            completion(.failure(.init("Could not create Lid Desktop on this Mac.")))
            return
        }
        self.screen = screen
        self.host = host
        self.peer = peer
        active = true
        message = String(localized: "Preparing the virtual display and Mac power…")
        let token = UUID()
        preparation = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.preparation == token else { return }
            stopAfterFailure("Closed-lid preparation timed out. Check the Mac settings and try again.")
        }

        let connection = NSXPCConnection(machServiceName: LidPowerService.identifier, options: .privileged)
        self.connection = connection
        connection.setCodeSigningRequirement(#"anchor apple generic and identifier "com.daokaihua.airpointerremote.direct.power" and certificate leaf[subject.OU] = "4AN6PV98G7""#)
        connection.remoteObjectInterface = NSXPCInterface(with: LidPowerProtocol.self)
        connection.resume()
        remote(connection)?.begin { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.preparation == token else { return }
                if let reason { self.stopAfterFailure(reason); return }
                self.activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                                                                 reason: "Closed-lid desktop shared with paired iPhone")
                self.scheduleRenewal(connection)
                self.waitForDisplay(token, id: screen.displayID, completion: completion)
            }
        }
    }

    private func remote(_ connection: NSXPCConnection) -> LidPowerProtocol? {
        connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                self.stopAfterFailure("The Mac power helper is unavailable. Check Background Items in System Settings.")
            }
        } as? LidPowerProtocol
    }

    private func waitForDisplay(_ token: UUID, id: CGDirectDisplayID,
                                completion: @escaping (Result<CGDirectDisplayID, StringError>) -> Void) {
        guard preparation == token else { return }
        if CGDisplayIsActive(id) != 0 {
            preparation = nil
            message = String(localized: "Waiting for the first iPhone frame…")
            completion(.success(id))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.waitForDisplay(token, id: id, completion: completion)
            }
        }
    }

    private func scheduleRenewal(_ connection: NSXPCConnection) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            remote(connection)?.renew { [weak self, weak connection] reason, warning in
                DispatchQueue.main.async {
                    guard let self, let connection, self.connection === connection else { return }
                    if let reason { self.stopAfterFailure(reason) }
                    else {
                        if self.powerWarning != warning { self.powerWarning = warning }
                        self.host?.closedLidPowerWarning = warning
                        self.scheduleRenewal(connection)
                    }
                }
            }
        }
    }

    func firstFrame(for host: LinkedHost) {
        guard self.host === host, !sharing else { return }
        sharing = true
        message = ""
        switchWhenReady()
    }

    func sharingEnded(_ host: LinkedHost, mayReconnect: Bool) {
        guard self.host === host else { return }
        self.host = nil
        switchingDisplay = false
        sharing = false
        if mayReconnect, activity != nil {
            message = String(localized: "Waiting up to 60 seconds for your iPhone to reconnect…")
            let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
                self?.stop(reason: "The iPhone did not reconnect. Normal sleep restored.")
            }
            reconnectTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            release()
        }
    }

    func cancelReconnect(from peer: String) {
        guard reconnectTimer != nil, self.peer == peer else { return }
        stop()
    }

    func stop(reason: String = "Closed-lid sharing ended on the Mac.") {
        let current = host
        host = nil
        release()
        message = Bundle.main.localizedString(forKey: reason, value: reason, table: nil)
        current?.stop(reason)
    }

    private func release() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        preparation = nil
        requestedBuiltIn = false
        enteringLidForExistingShare = false
        switchingDisplay = false
        sharing = false
        active = false
        powerWarning = nil
        peer = nil
        screen = nil
        brightness.update(enabled: false)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if let connection {
            self.connection = nil
            endingPower = true
            let finish: (String?) -> Void = { [weak self] reason in
                connection.invalidate()
                DispatchQueue.main.async {
                    guard let self, self.endingPower else { return }
                    self.endingPower = false
                    if let reason { self.message = Bundle.main.localizedString(forKey: reason, value: reason, table: nil) }
                }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil) } as? LidPowerProtocol
            proxy?.end(reply: finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                connection.invalidate()
            }
        }
    }

    func moveFocusedWindow() -> Bool {
        guard sharing, !lidClosed, let screen,
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return false }
        let application = AXUIElementCreateApplication(front.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let window = value as! AXUIElement
        let bounds = CGDisplayBounds(screen.displayID)
        var point = CGPoint(x: bounds.minX + 24, y: bounds.minY + 42)
        guard let position = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
    }

    struct StringError: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }
}
