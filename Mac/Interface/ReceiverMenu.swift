import AppKit
import SwiftUI
import Carbon
import CoreBluetooth
import Network

final class ReceiverMenu: NSObject, NSMenuDelegate {
    private var dragPanel: NSPanel?
    private var permissionWindow: NSWindow?
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
        #if CLOSED_LID_DESKTOP
        ClosedLidWindow.shared.openPermissions = { [weak self] in self?.showSetup(focusing: $0) }
        #endif
        let menu = NSMenu()
        menu.addItem(status)
        menu.addItem(.separator())
        add(String(localized: "Permissions & Setup…"), #selector(showHelp), to: menu)
        for permissionItem in [accessibilityItem, screenRecordingItem, bluetoothItem] {
            permissionItem.target = self
            menu.addItem(permissionItem)
        }
        add(String(localized: "Show Running App in Finder"), #selector(revealRunningApp), to: menu)
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
        if !UserDefaults.standard.bool(forKey: "didShowPermissionSetup") {
            UserDefaults.standard.set(true, forKey: "didShowPermissionSetup")
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
        if let panel = dragPanel, panel.isVisible,
           (panel.identifier?.rawValue == "Privacy_Accessibility" && accessibility)
            || (panel.identifier?.rawValue == "Privacy_Bluetooth" && bluetooth)
            || (panel.identifier?.rawValue == "Privacy_ScreenCapture" && screenRecording) {
            panel.close()
        }
        if let panel = dragPanel, panel.isVisible { alignWithSettings(panel) }
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

    @objc private func showHelp() { showSetup() }
    @objc private func openAccessibility() { showSetup(focusing: "accessibility") }
    @objc private func openScreenRecording() { showSetup(focusing: "screen") }
    @objc private func openBluetooth() { showSetup(focusing: "bluetooth") }

    private func showSetup(focusing section: String? = nil) {
        let window = permissionWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 690),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        if permissionWindow == nil {
            window.isReleasedWhenClosed = false
            window.title = String(localized: "Permissions & Setup")
            window.minSize = NSSize(width: 440, height: 360)
            window.center()
            permissionWindow = window
        }
        window.contentView = NSHostingView(rootView: PermissionSetup(section: section, openPane: { [weak self] pane in self?.openPermissionPane(pane) }))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func openPermissionPane(_ pane: String) {
        dragPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 135),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "Permissions & Setup")
        panel.identifier = NSUserInterfaceItemIdentifier(pane)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: PermissionGuideCard(pane: pane, back: { [weak self] in
            self?.dragPanel?.close()
            self?.showSetup()
        }))
        if let frame = (permissionWindow?.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.minY + 16))
        }
        dragPanel = panel
        panel.orderFrontRegardless()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func alignWithSettings(_ panel: NSPanel) {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              settings.isActive, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? Int32 == settings.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 450, rect.height >= 300 else { continue }
            let frame = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { continue }
            let visible = screen.visibleFrame
            let x = min(max(frame.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
            let y = max(frame.minY - panel.frame.height - 4, visible.minY)
            let origin = CGPoint(x: x, y: y)
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            return
        }
    }

    @objc private func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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

private struct PermissionSetup: View {
    let section: String?
    let openPane: (String) -> Void
    private let appURL = Bundle.main.bundleURL
    @State private var pointer = CGPreflightPostEventAccess()
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var bluetooth = CBPeripheralManager.authorization

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable().frame(width: 54, height: 54).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Set up AirPointer Remote").font(.title.bold())
                            Text("Choose the permissions for the features you use.").foregroundStyle(.secondary)
                        }
                    }
                    if #available(macOS 15, *) {
                        row("Local Network", symbol: "network", state: networkStatus,
                            detail: "Tap Share on iPhone while both devices are on the same local network. Allow local network access on each device when asked. On Mac, review this app under Privacy & Security → Local Network.",
                            pane: "Privacy_LocalNetwork", request: checkNetwork)
                    }
                    row("Bluetooth", symbol: "antenna.radiowaves.left.and.right", state: bluetoothState,
                        detail: "Allow Bluetooth when prompted so your device can discover this Mac. If you declined, enable this app under Privacy & Security → Bluetooth.",
                        pane: "Privacy_Bluetooth").id("bluetooth")
                    row("Mouse Control", symbol: "cursorarrow", state: pointer ? "Allowed" : "Setup needed",
                        detail: "Open Privacy & Security → Accessibility and enable this app. If missing, click +, press ⇧⌘G, paste the copied app path, press Return, then click Open and enable it.",
                        pane: "Privacy_Accessibility", request: pointer ? nil : { _ = CGRequestPostEventAccess() }).id("accessibility")
                    row("Screen Recording", symbol: "display", state: screen ? "Allowed" : "Optional",
                        detail: "For one session, choose a display in the Mac sharing picker. To reuse a remembered display, enable this app under Privacy & Security → Screen & System Audio Recording. If missing, use + and the copied app path. Reopen the app if macOS asks.",
                        pane: "Privacy_ScreenCapture", request: screen ? nil : { _ = CGRequestScreenCaptureAccess() }).id("screen")
                    #if CLOSED_LID_DESKTOP
                    PowerPermissionCard(desktop: .shared).id("power")
                    #endif
                    Text("Return to AirPointer on your iPhone or watch, select this Mac, and confirm the matching code when prompted.")
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Find the running app") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(appURL.path).font(.callout).textSelection(.enabled)
                            HStack {
                                Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
                                Button("Copy App Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(appURL.path, forType: .string)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Check Again") { refresh() }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }.onAppear { if let section { DispatchQueue.main.async { reader.scrollTo(section, anchor: .top) } } }
        }
        .onDisappear { browser?.cancel(); browser = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @State private var browser: NWBrowser?
    @State private var networkStatus: LocalizedStringKey = "Check when sharing"

    private func checkNetwork() {
        browser?.cancel()
        let probe = NWBrowser(for: .bonjour(type: LinkedOffer.service, domain: nil), using: .tcp)
        browser = probe
        networkStatus = "Checking…"
        probe.stateUpdateHandler = { [weak probe] state in
            guard let probe, browser === probe else { return }
            switch state {
            case .waiting(.dns(let error)), .failed(.dns(let error)):
                if error == kDNSServiceErr_PolicyDenied { networkStatus = "Access blocked" }
            default: break
            }
        }
        probe.browseResultsChangedHandler = { [weak probe] results, _ in
            guard let probe, browser === probe, !results.isEmpty else { return }
            networkStatus = "Service discovered"
            probe.cancel()
            browser = nil
        }
        probe.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak probe] in
            guard let probe, browser === probe else { return }
            probe.cancel()
            browser = nil
            if networkStatus == "Checking…" { networkStatus = "Check when sharing" }
        }
    }

    private var bluetoothState: LocalizedStringKey {
        switch bluetooth {
        case .allowedAlways: return "Allowed"
        case .denied: return "Setup needed"
        case .restricted: return "Restricted by system"
        default: return "Awaiting permission"
        }
    }

    private func refresh() {
        pointer = CGPreflightPostEventAccess()
        screen = CGPreflightScreenCaptureAccess()
        bluetooth = CBPeripheralManager.authorization
    }

    private func row(_ title: LocalizedStringKey, symbol: String, state: LocalizedStringKey,
                     detail: LocalizedStringKey, pane: String, request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(summary(for: pane)).foregroundStyle(.secondary)
                DisclosureGroup("Instructions") {
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                }.font(.callout)
            }
            Spacer(minLength: 4)
            if (pane == "Privacy_Accessibility" && pointer) || (pane == "Privacy_ScreenCapture" && screen)
                || (pane == "Privacy_Bluetooth" && bluetooth == .allowedAlways) {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing) {
                    Button(pane == "Privacy_LocalNetwork" ? "Open Settings" : "Allow") {
                        request?()
                        refresh()
                        openPane(pane)
                    }.buttonStyle(.borderedProminent)
                    Text(state).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func summary(for pane: String) -> LocalizedStringKey {
        switch pane {
        case "Privacy_Bluetooth": "Discover and pair your iPhone or watch."
        case "Privacy_Accessibility": "Move, click, and drag the Mac pointer."
        case "Privacy_ScreenCapture": "Reuse a remembered display when sharing."
        default: "Connect the iPhone video stream to this Mac."
        }
    }
}

private struct PermissionGuideCard: View {
    let pane: String
    private var draggable: Bool { pane == "Privacy_Accessibility" || pane == "Privacy_ScreenCapture" }
    let back: () -> Void
    private let url = Bundle.main.bundleURL
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: back) { Image(systemName: "chevron.backward") }
                    .accessibilityLabel(Text("Permissions & Setup"))
                Image(systemName: "arrow.up").foregroundStyle(.tint)
                Text(instruction)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let appLabel = HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                Text(url.deletingPathExtension().lastPathComponent)
                Spacer()
                Image(systemName: draggable ? "hand.draw" : "switch.2")
            }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            if draggable { appLabel.onDrag { NSItemProvider(object: url as NSURL) } }
            else { appLabel }
        }.padding(12)
    }

    private var instruction: LocalizedStringKey {
        switch pane {
        case "Privacy_LocalNetwork": "Enable this app in Local Network. If it is missing, tap Share on the paired iPhone and allow access when prompted."
        case "Privacy_Bluetooth": "Enable this app in Bluetooth, then select this Mac on your iPhone or watch."
        default: "Drag this app into the permission list, then turn on its switch."
        }
    }
}

#if CLOSED_LID_DESKTOP
private struct PowerPermissionCard: View {
    @ObservedObject var desktop: ClosedLidDesktop
    @State private var registrationError = ""

    var body: some View {
        if desktop.supported {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.circle").font(.title2).foregroundStyle(.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Closed-Lid Power").font(.headline)
                    Text("Optional for sharing while the MacBook lid is closed.").foregroundStyle(.secondary)
                    if desktop.powerStatus == .requiresApproval {
                        Text("In System Settings, allow the AirPointer background service under Login Items. Return here to check its status.")
                            .font(.callout)
                    }
                    if !registrationError.isEmpty && desktop.powerStatus != .enabled {
                        Text(registrationError).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if desktop.powerStatus == .enabled {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(desktop.powerStatus == .requiresApproval ? "Approve in Settings" : "Set Up") {
                        desktop.setupPower()
                        registrationError = desktop.message
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
#endif
