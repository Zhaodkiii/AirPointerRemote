import OSLog
import QuartzCore
import ScreenCaptureKit
import AppKit
import ApplicationServices
import SwiftUI
import Carbon
import CoreBluetooth

final class ReceiverMenu: NSObject, NSMenuDelegate {
    private var lastPointerState: (ax: Bool, post: Bool)?
    private var dragPanel: NSPanel?
    private var transitionPanel: NSPanel?
    private var sourceCard: (NSRect, NSImage)?

    private let guidePlacement = PermissionGuidePlacement()
    private let settingsInspection = DispatchQueue(label: "AirPointer.PermissionSettings", qos: .userInitiated)
    private var inspectingSettings = false
    private var guideTimer: Timer?
    private var nextInspection: TimeInterval = 0
    private var anchorWindow: CGRect?
    private var permissionList: CGRect?
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
        let ax = AXIsProcessTrusted()
        if lastPointerState?.ax != ax || lastPointerState?.post != accessibility {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "AirPointer", category: "Permissions")
                .notice("Pointer permission: accessibility=\(ax, privacy: .public), postEvents=\(accessibility, privacy: .public)")
            lastPointerState = (ax, accessibility)
        }
        let screenRecording = CGPreflightScreenCaptureAccess()
        let bluetooth = CBPeripheralManager.authorization == .allowedAlways
        if let panel = dragPanel,
           (panel.identifier?.rawValue == "Privacy_Accessibility" && (accessibility || ax))
            || (panel.identifier?.rawValue == "Privacy_Bluetooth" && bluetooth)
            || (panel.identifier?.rawValue == "Privacy_ScreenCapture" && screenRecording) {
            if panel.identifier?.rawValue == "Privacy_Accessibility", !accessibility {
                showSetup(focusing: "accessibility")
            } else { dismissGuide() }
        }
        accessibilityItem.title = accessibility ? String(localized: "Accessibility: Pointer Control Allowed") : String(localized: "Allow Pointer Control in Accessibility…")
        if ax && !accessibility { accessibilityItem.title = String(localized: "Recheck Mouse Access") }
        screenRecordingItem.title = screenRecording ? String(localized: "Screen Recording: Access Allowed") : String(localized: "Allow Screen Recording for Remembered Displays…")
        bluetoothItem.title = bluetooth ? String(localized: "Bluetooth: Access Allowed") : String(localized: "Allow Bluetooth Access…")
        accessibilityItem.isEnabled = !accessibility
        screenRecordingItem.isEnabled = !screenRecording
        bluetoothItem.isEnabled = !bluetooth

        var missing: [String] = []
        if !accessibility { missing.append(ax ? String(localized: "Mouse Control") : String(localized: "Accessibility")) }
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
        let returningPane = dragPanel?.identifier?.rawValue
        let returningCard = dragPanel.flatMap { snapshot($0, rect: $0.contentView?.bounds) }
        dismissGuide()
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
        if let pane = returningPane, let card = returningCard {
            window.contentView?.layoutSubtreeIfNeeded()
            if let destination = rowSnapshot(pane)?.0 { animateCard(card, to: destination) }
        }
    }

    private func dismissGuide() {
        transitionPanel?.orderOut(nil)
        transitionPanel = nil
        sourceCard = nil
        guideTimer?.invalidate()
        guideTimer = nil
        dragPanel?.orderOut(nil)
        dragPanel = nil
        guidePlacement.isDragging = false
        guidePlacement.resetAlignment()
    }

    private func openPermissionPane(_ pane: String) {
        dismissGuide()
        sourceCard = rowSnapshot(pane)
        let size = NSSize(width: 460, height: 108)
        let panel = PermissionAccessoryPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "AirPointer Permission Guide")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        permissionList = nil
        panel.identifier = NSUserInterfaceItemIdentifier(pane)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        let content = NSHostingView(rootView: PermissionGuideCard(pane: pane, placement: guidePlacement, back: { [weak self] in
            self?.showSetup()
        }))
        content.sizingOptions = []
        panel.contentView = content
        panel.setContentSize(size)
        permissionWindow?.orderOut(nil)
        dragPanel = panel
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
        let openedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            if self.alignWithSettings(panel) {
                if !panel.isVisible { self.revealGuide(panel) }
            } else {
                panel.orderOut(nil)
                if ProcessInfo.processInfo.systemUptime - openedAt > 8,
                   NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").isEmpty {
                    self.dismissGuide()
                }
            }
        }
        guideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func snapshot(_ window: NSWindow, rect: CGRect?) -> (NSRect, NSImage)? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let view = window.contentView, let rect, !rect.isEmpty,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return (window.convertToScreen(view.convert(rect, to: nil)), image)
    }

    private func rowSnapshot(_ pane: String) -> (NSRect, NSImage)? {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "permission-row-" + pane { return view }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        guard let window = permissionWindow, let root = window.contentView, let row = find(root),
              !row.visibleRect.isEmpty else { return nil }
        return snapshot(window, rect: row.convert(row.bounds.intersection(row.visibleRect), to: root))
    }

    private func animateCard(_ card: (NSRect, NSImage), to destination: NSRect) {
        let overlay = PermissionAccessoryPanel(contentRect: card.0, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hidesOnDeactivate = false
        overlay.ignoresMouseEvents = true
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let image = NSImageView(image: card.1)
        image.imageScaling = .scaleAxesIndependently
        overlay.contentView = image
        transitionPanel?.orderOut(nil)
        transitionPanel = overlay
        overlay.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.88, 0.32, 1.12)
            overlay.animator().setFrame(destination, display: true)
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            overlay.orderOut(nil)
            if self?.transitionPanel === overlay { self?.transitionPanel = nil }
        }
    }

    private func revealGuide(_ panel: NSPanel) {
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        panel.orderFrontRegardless()
        if animate, let card = sourceCard { animateCard(card, to: panel.frame) }
        sourceCard = nil
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    @discardableResult
    private func alignWithSettings(_ panel: NSPanel) -> Bool {
        if guidePlacement.isDragging { return true }
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              settings.isActive, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? Int32 == settings.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 450, rect.height >= 300 else { continue }
            let frame = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { continue }
            let visible = screen.visibleFrame
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            if anchorWindow != rect { permissionList = nil; anchorWindow = rect }
            inspectPermissionList(in: settings, window: rect, id: windowID, panel: panel)
            let list = permissionList.map {
                CGRect(x: $0.minX, y: primary.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
            }.flatMap { frame.contains($0) ? $0 : nil }
            let pane = panel.identifier?.rawValue
            let addRowPane = pane == "Privacy_Accessibility" || pane == "Privacy_ScreenCapture"
            if addRowPane { guidePlacement.trackPointer(in: frame, panel: panel.frame, detected: list != nil) }
            let estimate = guidePlacement.offsetBelowTop.map { frame.maxY - $0 }
            let estimatedBottom = estimate ?? (addRowPane ? max(frame.minY, frame.maxY - (pane == "Privacy_ScreenCapture" ? 475 : 449)) : frame.minY)
            let dock = PermissionGuidePlacement.dock(to: frame, list: list, estimatedBottom: estimatedBottom, within: visible)
            if panel.frame != dock { panel.setFrame(dock, display: true) }
            return true
        }
        return false
    }

    private func inspectPermissionList(in settings: NSRunningApplication, window: CGRect, id: CGWindowID, panel: NSPanel) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !inspectingSettings, now >= nextInspection else { return }
        nextInspection = now + 1
        inspectingSettings = true
        let pid = settings.processIdentifier
        let hasAddRow = ["Privacy_Accessibility", "Privacy_ScreenCapture"].contains(panel.identifier?.rawValue ?? "")
        settingsInspection.async { [weak self, weak panel] in
            let ax = AXIsProcessTrusted() ? PermissionGuidePlacement.permissionList(pid: pid, in: window, addRow: hasAddRow) : nil
            Task {
                var anchor = ax
                if anchor == nil, hasAddRow, CGPreflightScreenCaptureAccess() {
                    anchor = await PermissionGuidePlacement.visibleAddRow(id: id, in: window)
                }
                let result = anchor
                await MainActor.run { [weak self, weak panel] in
                    guard let self else { return }
                    self.inspectingSettings = false
                    guard let panel, self.dragPanel === panel, self.anchorWindow == window else { return }
                    self.permissionList = result
                }
            }
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
    @State private var axTrusted = AXIsProcessTrusted()
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
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
        axTrusted = AXIsProcessTrusted()
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
            } else if pane == "Privacy_Accessibility" && axTrusted {
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Accessibility allowed", systemImage: "checkmark.circle")
                    Text("Mouse events pending").font(.caption).foregroundStyle(.secondary)
                    Button("Recheck Mouse Access") {
                        _ = CGRequestPostEventAccess()
                        refresh()
                    }
                    Button("Reopen AirPointer") { reopen() }
                }
            } else {
                VStack(alignment: .trailing) {
                    Button("Allow") {
                        request?()
                        refresh()
                        if pane != "Privacy_Accessibility" || (!pointer && !axTrusted) { openPane(pane) }
                    }.buttonStyle(.borderedProminent)
                    Text(state).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .background(PermissionRowMarker(pane: pane))
    }

    private func reopen() {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"", "reopen", String(ProcessInfo.processInfo.processIdentifier), appURL.path]
        do { try launcher.run(); NSApp.terminate(nil) } catch { NSSound.beep() }
    }

    private func summary(for pane: String) -> LocalizedStringKey {
        switch pane {
        case "Privacy_Bluetooth": "Discover and pair your iPhone or watch."
        case "Privacy_Accessibility": "Move, click, and drag the Mac pointer."
        default: "Reuse a remembered display when sharing."
        }
    }
}

private struct PermissionRowMarker: NSViewRepresentable {
    let pane: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("permission-row-" + pane)
    }
}

private final class PermissionGuidePlacement: ObservableObject {
    var isDragging = false

    static func permissionList(pid: pid_t, in window: CGRect, addRow: Bool) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }

        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
              let front = windows.first else { return nil }
        var children = [front]
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18
        while index < children.count, index < 100, ProcessInfo.processInfo.systemUptime < deadline {
            let element = children[index]
            index += 1
            let role = attribute(element, kAXRoleAttribute) as? String
            let isAdd = addRow && role == kAXButtonRole && [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].contains { key in
                let label = (attribute(element, key) as? String ?? "").lowercased()
                return ["add", "+", "添加", "新增", "add application", "添加应用程序"].contains(label)
            }
            if isAdd || (!addRow && (role == kAXListRole || role == kAXTableRole)),
               let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
               let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                if AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                   AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
                    let rect = CGRect(origin: origin, size: dimensions)
                    if isAdd, window.contains(rect), rect.minX > window.minX + window.width * 0.2, rect.width < 64 {
                        return rowAnchor(center: CGPoint(x: rect.midX, y: rect.midY), window: window)
                    }
                    if !addRow, window.contains(rect), rect.midX > window.midX, rect.width > 180, rect.height > 60 {
                        return rect
                    }
                }
            }
            if let nested = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                children.append(contentsOf: nested.prefix(30))
            }
        }
        return nil
    }

    @Published var locating = false
    @Published var detected = false
    private var hover: (point: CGPoint, start: TimeInterval)?
    var offsetBelowTop: CGFloat?

    func resetAlignment() {
        locating = false
        detected = false
        offsetBelowTop = nil
        hover = nil
    }

    func trackPointer(in window: CGRect, panel: CGRect, detected found: Bool) {
        if detected != found { detected = found }
        if found && locating { locating = false }
        guard locating else { hover = nil; return }
        let p = NSEvent.mouseLocation
        guard window.contains(p), !panel.contains(p) else { hover = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let hover, hypot(p.x - hover.point.x, p.y - hover.point.y) < 3 {
            if now - hover.start >= 1 {
                offsetBelowTop = window.maxY - p.y + 12
                locating = false
            }
        } else { hover = (p, now) }
    }

    // Coordinates here use the window server's top-left origin, in logical points.
    static func rowAnchor(center: CGPoint, window: CGRect) -> CGRect {
        let left = max(window.minX, center.x - 12)
        return CGRect(x: left, y: center.y - 12, width: max(1, window.maxX - 20 - left), height: 24)
    }

    static func visibleAddRow(id: CGWindowID, in window: CGRect) async -> CGRect? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let target = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(window.width)
        config.height = Int(window.height)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let point = addButton(in: image) else { return nil }
        return rowAnchor(center: CGPoint(x: window.minX + point.x, y: window.minY + point.y), window: window)
    }

    // Match the adjacent plus and minus glyphs at one pixel per logical point.
    // Sample both polarities so the match works in light and dark appearances.
    static func addButton(in image: CGImage) -> CGPoint? {
        let w = image.width, h = image.height
        guard w > 100, h > 100, let bitmap = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
            let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for y in 50..<(h - 8) {
            for x in 8..<min(w - 38, w / 2) {
                let i = y * w + x
                let bg = Int(bytes[i - 3*w - 3])
                let contrast = Int(bytes[i]) - bg
                guard abs(contrast) > 40 else { continue }
                let sign = contrast > 0 ? 1 : -1
                func stroke(_ offset: Int, _ threshold: Int) -> Bool { (Int(bytes[i + offset]) - bg) * sign > threshold }
                guard [-3, 3, -3*w, 3*w].allSatisfy({ stroke($0, 27) }),
                      [-3*w+3, 3*w-3, 3*w+3, -6, 6].allSatisfy({ !stroke($0, 22) }) else { continue }
                // The toolbar has a vertical separator between the two controls.
                // Requiring it also excludes plus-shaped strokes in app names.
                guard (11...14).contains(where: { dx in
                    [-7, 0, 7].allSatisfy { dy in abs(Int(bytes[i + dx + dy*w]) - Int(bytes[i + dx + 3 + dy*w])) > 5 }
                }) else { continue }
                for gap in 23...27 where [gap-3, gap, gap+3].allSatisfy({ stroke($0, 15) }) &&
                    !stroke(gap-3*w, 15) && !stroke(gap+3*w, 15) && !stroke(gap+6, 15) {
                    return CGPoint(x: x, y: y)
                }
            }
        }
        return nil
    }

    static func dock(to settings: CGRect, list: CGRect?, estimatedBottom: CGFloat, within visible: CGRect) -> CGRect {
        // Before Accessibility is granted, only the Settings window bounds are available.
        // Reserve its sidebar and anchor the strip to the detail pane on that display.
        let detail = list ?? settings.divided(
            atDistance: min(220, settings.width * 0.30), from: .minXEdge).remainder
        let width = min(520, detail.width - 16, visible.width)
        let height: CGFloat = 108
        let x = min(max(detail.midX - width / 2, visible.minX), visible.maxX - width)
        let y = min(max((list?.minY ?? estimatedBottom) - height - 4, visible.minY), visible.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height)
    }
}

private final class PermissionAccessoryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PermissionGuideCard: View {
    let pane: String
    @ObservedObject var placement: PermissionGuidePlacement
    private var draggable: Bool { pane == "Privacy_Accessibility" || pane == "Privacy_ScreenCapture" }
    let back: () -> Void
    private let url = Bundle.main.bundleURL
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: back) { Image(systemName: "chevron.backward") }
                    .accessibilityLabel(Text("Permissions & Setup"))
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(placement.locating ? "Hold the pointer over the + button for one second." : instruction).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if draggable && !placement.detected {
                    Button(placement.locating ? "Cancel" : "Align to +") { placement.locating.toggle() }
                        .controlSize(.small)
                }
            }
            let appLabel = HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                Text(url.deletingPathExtension().lastPathComponent)
                Spacer()
                Image(systemName: draggable ? "hand.draw" : "switch.2")
            }.padding(8).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.secondary.opacity(0.3)))
            if draggable {
                appLabel.overlay {
                    PermissionAppDragSource(url: url) { placement.isDragging = $0 }
                        .accessibilityHidden(true)
                }
            }
            else { appLabel }
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.3)))
    }

    private var instruction: LocalizedStringKey {
        switch pane {
        case "Privacy_Bluetooth": "Enable this app in Bluetooth, then select this Mac on your iPhone or watch."
        default: "Drag this app into the settings list if missing, then turn on its switch."
        }
    }
}

private struct PermissionAppDragSource: NSViewRepresentable {
    let url: URL
    let onDragChange: (Bool) -> Void

    func makeNSView(context: Context) -> DragView { DragView(url: url, onDragChange: onDragChange) }
    func updateNSView(_ view: DragView, context: Context) { view.onDragChange = onDragChange }

    final class DragView: NSView, NSDraggingSource {
        let url: URL
        var onDragChange: (Bool) -> Void
        private var press: NSPoint?

        init(url: URL, onDragChange: @escaping (Bool) -> Void) {
            self.url = url
            self.onDragChange = onDragChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { press = event.locationInWindow }
        override func mouseUp(with event: NSEvent) { press = nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDragged(with event: NSEvent) {
            guard let press, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) >= 3 else { return }
            self.press = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let point = convert(event.locationInWindow, from: nil)
            let image = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36), contents: image)
            onDragChange(true)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onDragChange(false)
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
