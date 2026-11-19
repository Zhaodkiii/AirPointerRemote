import AppKit
import Carbon
import CoreBluetooth

final class ReceiverMenu: NSObject, NSMenuDelegate {
    private var rememberItem: NSMenuItem!
    private var forgetItem: NSMenuItem!
    private let receiver: Receiver
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let status = NSMenuItem(title: "Waiting for a device", action: nil, keyEquivalent: "")
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
        add("Show Running App in Finder", #selector(revealRunningApp), to: menu)
        add("Connection Help…", #selector(showHelp), to: menu)
        menu.addItem(.separator())
        rememberItem = add("Remember Display for This iPhone", #selector(toggleRemember), to: menu)
        forgetItem = add("Forget All Remembered Displays", #selector(forgetDisplays), to: menu)
        menu.delegate = self
        menu.autoenablesItems = false
        status.isEnabled = false
        menu.addItem(.separator())
        pauseItem = add("Pause Control", #selector(togglePause(_:)), to: menu)
        let stop = add("Stop All Control", #selector(stopControl), to: menu)
        stop.keyEquivalent = "."
        stop.keyEquivalentModifierMask = [.control, .option, .command]
        add("Revoke All iPhone Pairings", #selector(revoke), to: menu)
        menu.addItem(.separator())
        add("Quit AirPointer Remote", #selector(quit), to: menu)
        item.menu = menu
        receiver.onPhoneState = { [weak self] text in self?.status.title = text }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if !UserDefaults.standard.bool(forKey: "didShowConnectionHelp") {
            UserDefaults.standard.set(true, forKey: "didShowConnectionHelp")
            DispatchQueue.main.async { [weak self] in self?.showHelp() }
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
        accessibilityItem.title = accessibility ? "Accessibility: Pointer Control Allowed" : "Allow Pointer Control in Accessibility…"
        screenRecordingItem.title = screenRecording ? "Screen Recording: Access Allowed" : "Allow Screen Recording for Remembered Displays…"
        bluetoothItem.title = bluetooth ? "Bluetooth: Access Allowed" : "Allow Bluetooth Access…"
        accessibilityItem.isEnabled = !accessibility
        screenRecordingItem.isEnabled = !screenRecording
        bluetoothItem.isEnabled = !bluetooth

        var missing: [String] = []
        if !accessibility { missing.append("Accessibility") }
        if !bluetooth { missing.append("Bluetooth") }
        if !screenRecording && LinkedHost.hasRememberedDisplays { missing.append("Screen Recording") }
        let description = missing.isEmpty ? "AirPointer Remote" : "AirPointer Remote — Allow " + missing.joined(separator: ", ")
        item.button?.image = NSImage(systemSymbolName: missing.isEmpty ? "cursorarrow.rays" : "exclamationmark.circle",
                                     accessibilityDescription: description)
        item.button?.setAccessibilityLabel(description)
        item.button?.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        let host = LinkedHost.sharing
        rememberItem.title = host.map { "Remember “\($0.displayName)” for \($0.phoneName)" } ?? "Remember Display for This iPhone (Start Sharing First)"
        rememberItem.state = host?.remembersDisplay == true ? .on : .off
        rememberItem.isEnabled = host?.canRememberDisplay == true
        forgetItem.isEnabled = LinkedHost.hasRememberedDisplays
    }

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
        alert.messageText = "Connect an iPhone or Apple Watch"
        alert.informativeText = "Keep AirPointer Remote running on this Mac. Turn on Bluetooth on both devices. In System Settings → Privacy & Security → Accessibility, allow AirPointer Remote to move and click the pointer. Then select this Mac on your other device and confirm the connection here."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { openAccessibility() }
    }

    @objc private func openAccessibility() {
        showPermissionGuide(
            title: "Allow pointer control on this Mac",
            pane: "Accessibility",
            details: "Enable AirPointer Remote to move, click, and drag the pointer from your iPhone or Apple Watch.",
            settings: "Privacy_Accessibility"
        )
    }

    @objc private func openScreenRecording() {
        showPermissionGuide(
            title: "Allow Screen Recording for remembered displays",
            pane: "Screen & System Audio Recording",
            details: "This lets a paired iPhone reuse a display you remembered. You can also choose a screen for an individual sharing session with the system picker.",
            settings: "Privacy_ScreenCapture"
        )
    }

    private func showPermissionGuide(title: String, pane: String, details: String, settings: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = """
            \(details)

            Open System Settings → Privacy & Security → \(pane). If the switch is already on for another copy, use the − and + buttons to replace that entry with the running app, then reopen it.

            Running app: \(Bundle.main.bundleURL.path)
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Show App in Finder")
        alert.addButton(withTitle: "Later")
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
        sender.title = paused ? "Resume Control" : "Pause Control"
        receiver.pauseControl(paused)
    }
    @objc func stopControl() {
        paused = true
        pauseItem?.title = "Resume Control"
        receiver.stopControl()
        status.title = "Control stopped. Resume from this menu."
    }
    @objc private func revoke() {
        LinkedHost.forgetAllDisplays()
        receiver.revokePhones()
        status.title = "iPhone pairings revoked."
    }
    @objc private func quit() {
        receiver.stopControl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
    }
}
