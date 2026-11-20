import AppKit
import Carbon
import CoreBluetooth

final class ReceiverMenu: NSObject, NSMenuDelegate {
    private var rememberItem: NSMenuItem!
    private var forgetItem: NSMenuItem!
    #if CLOSED_LID_DESKTOP
    private var lidSettings: NSMenuItem!
    private var lidStop: NSMenuItem!
    private var lidStart: NSMenuItem!
    private var lidMoveWindow: NSMenuItem!
    #endif
    private let receiver: Receiver
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let status = NSMenuItem(title: String(localized: "Waiting for a device"), action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    private let screenRecordingItem = NSMenuItem(title: "", action: #selector(openScreenRecording), keyEquivalent: "")
    private let bluetoothItem = NSMenuItem(title: "", action: #selector(openBluetooth), keyEquivalent: "")
    private var paused = false
    private var pauseItem: NSMenuItem?
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(receiver: Receiver) {
        self.receiver = receiver
        super.init()
        let menu = NSMenu()
        menu.addItem(status)
        menu.addItem(.separator())
        for permissionItem in [accessibilityItem, screenRecordingItem, bluetoothItem] {
            permissionItem.target = self
            menu.addItem(permissionItem)
        }
        add(String(localized: "Show Running App in Finder"), #selector(revealRunningApp), to: menu)
        add(String(localized: "Connection Help…"), #selector(showHelp), to: menu)
        menu.addItem(.separator())
        rememberItem = add(String(localized: "Remember Display for This iPhone"), #selector(toggleRemember), to: menu)
        forgetItem = add(String(localized: "Forget All Remembered Displays"), #selector(forgetDisplays), to: menu)
        #if CLOSED_LID_DESKTOP
        menu.addItem(.separator())
        lidSettings = add(String(localized: "Closed-Lid Desktop…"), #selector(showLidSettings), to: menu)
        lidStart = add(String(localized: "Switch to Lid Desktop"), #selector(switchToLidDesktop), to: menu)
        lidStop = add(String(localized: "Switch to Built-in Display"), #selector(switchFromLidDesktop), to: menu)
        lidMoveWindow = add(String(localized: "Move Focused Window to Lid Desktop"), #selector(moveLidWindow), to: menu)
        #endif
        menu.delegate = self
        menu.autoenablesItems = false
        status.isEnabled = false
        menu.addItem(.separator())
        pauseItem = add(String(localized: "Pause Control"), #selector(togglePause(_:)), to: menu)
        let stop = add(String(localized: "Stop All Control"), #selector(stopControl), to: menu)
        stop.keyEquivalent = "."
        stop.keyEquivalentModifierMask = [.control, .option, .command]
        add(String(localized: "Revoke All iPhone Pairings"), #selector(revoke), to: menu)
        menu.addItem(.separator())
        add(String(localized: "Quit AirPointer Remote"), #selector(quit), to: menu)
        item.menu = menu
        receiver.onPhoneState = { [weak self] text in self?.status.title = text }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if !UserDefaults.standard.bool(forKey: "didShowConnectionHelp") {
            UserDefaults.standard.set(true, forKey: "didShowConnectionHelp")
            #if CLOSED_LID_DESKTOP
            DispatchQueue.main.async { ClosedLidWindow.shared.show() }
            #else
            DispatchQueue.main.async { [weak self] in self?.showHelp() }
            #endif
        }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let menu = Unmanaged<ReceiverMenu>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { menu.stopControl() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x57505452, id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    @discardableResult private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func refresh() {
        let accessibility = CGPreflightPostEventAccess()
        let screenRecording = CGPreflightScreenCaptureAccess()
        let bluetooth = CBPeripheralManager.authorization == .allowedAlways
        accessibilityItem.title = accessibility ? String(localized: "Accessibility: Pointer Control Allowed") : String(localized: "Allow Pointer Control in Accessibility…")
        screenRecordingItem.title = screenRecording ? String(localized: "Screen Recording: Access Allowed") : String(localized: "Allow Screen Recording for Remembered Displays…")
        bluetoothItem.title = bluetooth ? String(localized: "Bluetooth: Access Allowed") : String(localized: "Allow Bluetooth Access…")
        accessibilityItem.isEnabled = !accessibility
        screenRecordingItem.isEnabled = !screenRecording
        bluetoothItem.isEnabled = !bluetooth

        var missing: [String] = []
        if !accessibility { missing.append(String(localized: "Accessibility")) }
        if !bluetooth { missing.append(String(localized: "Bluetooth")) }
        if !screenRecording && LinkedHost.hasRememberedDisplays { missing.append(String(localized: "Screen Recording")) }
        let description = missing.isEmpty ? "AirPointer Remote" : String(localized: "AirPointer Remote — Allow ") + missing.joined(separator: ", ")
        item.button?.image = NSImage(systemSymbolName: missing.isEmpty ? "cursorarrow.rays" : "exclamationmark.circle",
                                     accessibilityDescription: description)
        item.button?.setAccessibilityLabel(description)
        item.button?.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        let host = LinkedHost.sharing
        rememberItem.title = host.map { String(localized: "Remember “\($0.displayName)” for \($0.phoneName)") } ?? String(localized: "Remember Display for This iPhone (Start Sharing First)")
        rememberItem.state = host?.remembersDisplay == true ? .on : .off
        rememberItem.isEnabled = host?.canRememberDisplay == true
        forgetItem.isEnabled = LinkedHost.hasRememberedDisplays
        #if CLOSED_LID_DESKTOP
        let desktop = ClosedLidDesktop.shared
        desktop.refresh()
        lidStart.isHidden = !desktop.enabled || !desktop.sharingAnotherDisplay || desktop.active
        lidStart.isEnabled = desktop.canSwitchToLidDesktop
        lidSettings.state = desktop.enabled ? .on : .off
        lidStop.isHidden = !desktop.active
        lidStop.isEnabled = !desktop.switchingDisplay
        lidMoveWindow.isHidden = !desktop.sharing || desktop.lidClosed
        lidMoveWindow.isEnabled = desktop.pointerAllowed
        #endif
    }

    #if CLOSED_LID_DESKTOP
    @objc private func showLidSettings() { ClosedLidWindow.shared.show() }
    @objc private func switchToLidDesktop() { ClosedLidDesktop.shared.requestLidDesktop() }
    @objc private func switchFromLidDesktop() { ClosedLidDesktop.shared.requestBuiltInDisplay() }
    @objc private func moveLidWindow() {
        guard !ClosedLidDesktop.shared.moveFocusedWindow() else { return }
        NSSound.beep()
        status.title = String(localized: "Select a movable Mac window and try again.")
    }
    #endif

    @objc private func toggleRemember() {
        guard let host = LinkedHost.sharing, host.canRememberDisplay else { return }
        let enable = !host.remembersDisplay
        host.setRemembered(enable)
        if enable && !CGPreflightScreenCaptureAccess() {
            openScreenRecording()
        }
    }
    @objc private func forgetDisplays() { LinkedHost.forgetAllDisplays() }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect an iPhone or Apple Watch")
        alert.informativeText = String(localized: "Keep AirPointer Remote running on this Mac. Turn on Bluetooth on both devices. In System Settings → Privacy & Security → Accessibility, allow AirPointer Remote to move and click the pointer. Then select this Mac on your other device and confirm the connection here.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Open Accessibility Settings"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { openAccessibility() }
    }

    @objc private func openAccessibility() {
        showPermissionGuide(
            title: String(localized: "Allow pointer control on this Mac"),
            pane: String(localized: "Accessibility"),
            details: String(localized: "Enable AirPointer Remote to move, click, and drag the pointer from your iPhone or Apple Watch."),
            settings: "Privacy_Accessibility"
        )
    }

    @objc private func openScreenRecording() {
        showPermissionGuide(
            title: String(localized: "Allow Screen Recording for remembered displays"),
            pane: String(localized: "Screen & System Audio Recording"),
            details: String(localized: "This lets a paired iPhone reuse a display you remembered. You can also choose a screen for an individual sharing session with the system picker."),
            settings: "Privacy_ScreenCapture"
        )
    }

    private func showPermissionGuide(title: String, pane: String, details: String, settings: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: """
            \(details)

            Open System Settings → Privacy & Security → \(pane). If the switch is already on for another copy, use the − and + buttons to replace that entry with the running app, then reopen it.

            Running app: \(Bundle.main.bundleURL.path)
            """)
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Show App in Finder"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settings)")!)
        case .alertSecondButtonReturn:
            revealRunningApp()
        default:
            break
        }
    }

    @objc private func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    @objc private func openBluetooth() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
    }
    @objc private func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        sender.title = paused ? String(localized: "Resume Control") : String(localized: "Pause Control")
        #if CLOSED_LID_DESKTOP
        if paused { ClosedLidDesktop.shared.stop() }
        #endif
        receiver.pauseControl(paused)
    }
    @objc func stopControl() {
        paused = true
        pauseItem?.title = String(localized: "Resume Control")
        #if CLOSED_LID_DESKTOP
        ClosedLidDesktop.shared.stop()
        #endif
        receiver.stopControl()
        status.title = String(localized: "Control stopped. Resume from this menu.")
    }
    @objc private func revoke() {
        #if CLOSED_LID_DESKTOP
        ClosedLidDesktop.shared.stop()
        #endif
        LinkedHost.forgetAllDisplays()
        receiver.revokePhones()
        status.title = String(localized: "iPhone pairings revoked.")
    }
    @objc private func quit() {
        #if CLOSED_LID_DESKTOP
        ClosedLidDesktop.shared.stop()
        #endif
        receiver.stopControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
    }
}
