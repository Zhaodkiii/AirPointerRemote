import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: RemoteController
    @ObservedObject var connection: PhoneConnection
    @StateObject private var sharing = LinkedClient()
    @Environment(\.scenePhase) private var phase
    @State private var inlineRequested = false
    @State private var linkedScreen = false
    @State private var preferAdaptiveDesktop = false
    @AppStorage("linked.autoPictureInPicture") private var automaticPiP = true
    @State private var pendingDesktopPair = false
    @State private var systemDesktop = false
    @State private var settings = false
    @State private var showHelp = false
    @State private var showSetup = false
    @State private var confirmNewIdentity = false

    @AppStorage("pad.zoom") private var zoomGesture = true
    @AppStorage("pad.fit") private var fitGesture = true
    @AppStorage("pad.rotate") private var rotateGesture = true
    @AppStorage("pad.pages") private var pagesGesture = false
    @AppStorage("pad.notifications") private var notificationsGesture = true
    @AppStorage("pad.spaces") private var spacesGesture = true
    @AppStorage("pad.four") private var fourGesture = true

    var body: some View {
        NavigationStack {
            VStack(spacing: inlineWorkspace ? 4 : 16) {
                if sharing.pipState == .active && !linkedScreen {
                    Button("Return to Shared Screen") { sharing.pictureInPicture?.restore() }
                    Button("Stop Sharing", role: .destructive) { sharing.end() }
                }
                if inlineWorkspace {
                    connectionStatus.padding(.horizontal, 12)
                    LinkedWorkspace(client: sharing, inline: true, startPiP: startPiP, automaticPiP: $automaticPiP)
                } else if connection.connected && !systemDesktop {
                    connectionStatus
                    remote
                } else {
                    connectionHome
                }
            }
            .padding(inlineWorkspace ? 0 : 16)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("AirPointer Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(inlineWorkspace ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("How to Use")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !systemDesktop && (connection.connected || sharing.running || sharing.canRetrySharing) {
                        Button {
                            if sharing.pipState == .active { sharing.pictureInPicture?.restore(); return }
                            controller.suspendInteraction(true)
                            if sharing.running { connection.send(.init(.linkedInput)) }
                            sharing.hideKeyboard()
                            preferAdaptiveDesktop = false
                            linkedScreen = true
                        } label: {
                            Image(systemName: "rectangle.connected.to.line.below")
                        }
                        .accessibilityLabel("Linked Screen")
                    }
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings")
                }
            }
            .fullScreenCover(isPresented: $linkedScreen, onDismiss: {
                if sharing.pipState == .idle && !sharing.running { inlineRequested = false }
                updateSharingPresentation()
            }) {
                LinkedScreenView(connection: connection, client: sharing, startPiP: startPiP, automaticPiP: $automaticPiP,
                                 preferAdaptive: preferAdaptiveDesktop)
            }
            .onAppear {
                let cover = $linkedScreen
                let inline = $inlineRequested
                let preferences = $settings
                let help = $showHelp
                let setup = $showSetup
                sharing.minimizeForPictureInPicture = {
                    inline.wrappedValue = false
                    cover.wrappedValue = false
                }
                sharing.showPictureInPictureWorkspace = { workspace in
                    preferences.wrappedValue = false
                    help.wrappedValue = false
                    setup.wrappedValue = false
                    inline.wrappedValue = workspace == .inline
                    cover.wrappedValue = workspace == .linkedScreen
                }
                updateSharingPresentation()
            }
            .onChange(of: linkedScreen) { _, _ in updateSharingPresentation() }
            .onChange(of: sharing.pipState) { _, _ in updateSharingPresentation() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                if sharing.pipState != .idle { sharing.end(String(localized: "Sharing stopped when iPhone locked."), keepDraft: true) }
            }
            .onChange(of: sharing.pipSupportedByMac) { _, _ in updateSharingPresentation() }
            .onChange(of: automaticPiP) { _, _ in updateSharingPresentation() }
            .alert("Picture in Picture couldn’t start", isPresented: $sharing.pipError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your desktop is still shared. Try Picture in Picture again.")
            }
            .onChange(of: inlineWorkspace) { _, showing in
                updateSharingPresentation()
                if showing && sharing.live { connection.send(.init(.linkedInput)) }
            }
            .onChange(of: sharing.live) { _, live in
                updateSharingPresentation()
                if live && linkedScreen { connection.send(.init(.linkedInput)) }
            }
            .onChange(of: systemDesktop) { _, _ in updateInputOwner() }
            .onChange(of: settings) { _, _ in updateSharingPresentation() }
            .onChange(of: showSetup) { _, _ in updateSharingPresentation() }
            .onChange(of: showHelp) { _, _ in updateSharingPresentation() }
            .onChange(of: connection.connected) { _, connected in
                sharing.connectionChanged(connection)
                if connected && pendingDesktopPair && systemDesktop { openAdaptiveDesktop() }
                pendingDesktopPair = false
            }
            .onChange(of: connection.macPaused) { _, paused in
                if paused { sharing.end(String(localized: "Control paused on the Mac.")) }
            }
            .onChange(of: phase, initial: true) { _, phase in
                sharing.sceneChanged(active: phase == .active, background: phase == .background, controller: controller)
            }
            .sheet(isPresented: $settings) { settingsView }
            .sheet(isPresented: $showSetup) {
                NavigationStack { setupGuide }
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showHelp) { helpView }
            .confirmationDialog("Replace saved Mac pairing?", isPresented: $confirmNewIdentity, titleVisibility: .visible) {
                Button("Forget and Re-pair", role: .destructive) { connection.retryChangedMac() }
            } message: {
                Text("Only continue if you recognize this Mac. You'll need to compare a new pairing code on both devices.")
            }

        }
    }

    private var inlineWorkspace: Bool {
        !systemDesktop && inlineRequested && sharing.pipState != .active && !linkedScreen && (sharing.live || sharing.resuming) && !controller.holdingLeft
    }

    private func updateInputOwner() {
        controller.suspendInteraction(systemDesktop || linkedScreen || inlineWorkspace || sharing.pipState != .idle || settings || showHelp || showSetup)
    }

    private func updateSharingPresentation() {
        updateInputOwner()
        if linkedScreen {
            sharing.workspace = .linkedScreen
        } else if inlineWorkspace && !settings && !showHelp && !showSetup {
            sharing.workspace = .inline
        } else {
            sharing.workspace = nil
        }
        sharing.pictureInPicture?.configure(automatic: automaticPiP,
            available: sharing.live && sharing.pipSupportedByMac && sharing.workspacePresented)
    }

    private func startPiP() {
        sharing.pictureInPicture?.start()
    }

    private func toggleInlineSharing() {
        if sharing.running {
            sharing.end()
            inlineRequested = false
        } else {
            inlineRequested = true
            sharing.start(connection, inline: true)
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: connection.connected ? "laptopcomputer" : "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(connection.connected && connection.accessibility ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.macName).font(.headline).lineLimit(1)
                if inlineWorkspace {
                    Button {
                        sharing.hideKeyboard()
                        sharing.end(keepDraft: true)
                        sharing.start(connection, inline: true, chooseDisplay: true)
                    } label: {
                        HStack(spacing: 4) {
                            Text(sharing.displayName).lineLimit(1)
                            Image(systemName: "chevron.down")
                        }
                    }
                    .font(.caption)
                    .disabled(!connection.connected || sharing.resuming)
                    .accessibilityLabel("Change shared display")
                } else {
                    Text(inlineRequested && connection.connected ? sharing.status : connection.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if connection.connected || (inlineWorkspace && sharing.running) {
                Button(action: toggleInlineSharing) {
                    HStack(spacing: 4) {
                        if sharing.running && !sharing.live { ProgressView().controlSize(.small) }
                        else { Image(systemName: sharing.live ? "stop.circle.fill" : "rectangle.on.rectangle") }
                        Text(sharing.running ? (sharing.live ? String(localized: "Stop") : String(localized: "Cancel")) : String(localized: "Share"))
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
                .tint(sharing.live ? .red : .accentColor)
                .disabled(!sharing.running && (controller.paused || connection.macPaused))
                .accessibilityLabel(sharing.running ? String(localized: "Stop inline screen sharing") : String(localized: "Share screen on this page"))
                Button {
                    if sharing.running { sharing.end(); inlineRequested = false }
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.paused ? "play.fill" : "pause.fill")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .disabled(!connection.connected)
                .accessibilityLabel(controller.paused ? String(localized: "Resume Control") : String(localized: "Pause Control"))
            }
        }
    }

    private var connectionHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect to a Mac").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { connectionChoices }
                    VStack(spacing: 10) { connectionChoices }
                }
                if systemDesktop {
                    SystemDesktopHome(
                        connection: connection,
                        openAdaptive: openAdaptiveDesktop,
                        pairing: { devices }
                    )
                } else { devices }
            }
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var connectionChoices: some View {
        connectionChoice("Bluetooth Remote", subtitle: "Trackpad and air mouse", icon: "cursorarrow.motionlines", desktop: false)
        connectionChoice("Built-in Screen Sharing", subtitle: "View and control the desktop", icon: "desktopcomputer", desktop: true)
    }

    private func connectionChoice(_ title: LocalizedStringKey, subtitle: LocalizedStringKey,
                                  icon: String, desktop: Bool) -> some View {
        let selected = systemDesktop == desktop
        return Button {
            if desktop { selectSystemDesktop() } else { systemDesktop = false }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.title3)
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.accentColor)
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 122, maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func openAdaptiveDesktop() {
        guard connection.connected else { return }
        if sharing.running { sharing.end(keepDraft: true); inlineRequested = false }
        preferAdaptiveDesktop = true
        controller.suspendInteraction(true)
        linkedScreen = true
    }

    private func selectSystemDesktop() {
        if sharing.running { sharing.end(keepDraft: true); inlineRequested = false }
        if connection.connecting && !connection.connected {
            if connection.pairingCode != nil { connection.rejectPairing() } else { connection.disconnect() }
        }
        systemDesktop = true
        updateInputOwner()
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby Macs").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Open AirPointer Remote on your Mac. Allow Bluetooth and Accessibility on the Mac, then select it below.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let code = connection.pairingCode {
                VStack(spacing: 12) {
                    Text("Compare Pairing Codes").font(.headline)
                    Text(code).font(.largeTitle.monospacedDigit().bold())
                    Text("If the code matches your Mac, confirm on both devices.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Codes Match — Connect") { connection.confirmPairing() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel Pairing", role: .cancel) { connection.rejectPairing() }
                }
                .frame(maxWidth: .infinity).padding()
            } else if connection.connecting {
                HStack {
                    ProgressView()
                    Text(connection.status).font(.subheadline)
                    Spacer(minLength: 0)
                    Button("Cancel Connection") { connection.disconnect() }.font(.subheadline)
                }
            } else {
                if connection.changedMac != nil {
                    Button("Forget and Re-pair…") { confirmNewIdentity = true }.buttonStyle(.bordered)
                }
                if connection.nearby.isEmpty {
                    Text(connection.bluetoothReady ? String(localized: "Looking for nearby Macs…") : connection.status)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(connection.nearby) { mac in
                    Button {
                        pendingDesktopPair = systemDesktop
                        connection.connect(mac)
                    } label: {
                        HStack {
                            Label(mac.name, systemImage: "laptopcomputer")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                Button("Set Up Your Mac", systemImage: "shippingbox") { showSetup = true }
                    .buttonStyle(.bordered)
                if !connection.bluetoothReady {
                    Button("Open iPhone Settings") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }.font(.footnote)
                }
            }
        }
    }

    private var setupGuide: some View {
        MacSetupGuide(connection: connection) {
            showSetup = false
            showHelp = false
        }
    }

    private var remote: some View {
        VStack(spacing: 12) {
            Picker("Control Mode", selection: $controller.mode) {
                ForEach(RemoteController.Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            if let message = controller.motionMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            if controller.mode != .trackpad {
                HStack {
                    Button { controller.calibrate() } label: { Label("Recenter", systemImage: "scope") }
                        .disabled(!controller.canControl)
                    Spacer()
                    Toggle("Continuous", isOn: $controller.continuous).fixedSize()
                }.font(.subheadline)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Color(uiColor: .secondarySystemGroupedBackground))
                VStack(spacing: 14) {
                    Image(systemName: controller.mode == .air ? "gyroscope" : "hand.draw")
                        .font(.system(size: 44, weight: .light))
                    Text(controller.paused || connection.macPaused ? String(localized: "Control is paused") : controller.mode == .air ? String(localized: "Hold Move and tilt your iPhone") : String(localized: "One finger to move · Two to scroll"))
                        .font(.headline)
                    Text(controller.mode == .hybrid ? String(localized: "Hold Move to aim. Release for touch control.") : controller.mode == .air ? String(localized: "Point the top of your iPhone at the Mac.") : String(localized: "Tap to click · Two-finger tap to right-click"))
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .padding()
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
                if controller.mode != .air {
                    TrackpadView(controller: controller, enabled: controller.canControl)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                HoldControl(title: String(localized: "Left Click"), enabled: controller.canControl) { controller.left($0, source: "button") }
                if controller.mode != .trackpad {
                    HoldControl(title: controller.airHeld ? String(localized: "Moving") : String(localized: "Hold to Move"), enabled: controller.canControl) { controller.setAirHeld($0) }
                }
                Button { controller.click(right: true) } label: {
                    Text("Right Click").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).disabled(!controller.canControl)
            }.frame(height: 68)
            HStack {
                HoldControl(title: String(localized: "Hold for Precision"), enabled: controller.canControl) { controller.precise = $0 }
                Button("Disconnect") { controller.stop(); connection.disconnect() }.buttonStyle(.bordered)
            }.frame(height: 44)
            Button("Built-in Screen Sharing", systemImage: "desktopcomputer", action: selectSystemDesktop)
                .font(.subheadline)
        }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Pointer") {
                    Text("Trackpad speed \(controller.touchSpeed, specifier: "%.1f")")
                    Slider(value: $controller.touchSpeed, in: 0.3...4)
                    Text("Air mouse sensitivity \(controller.airSpeed, specifier: "%.1f")")
                    Slider(value: $controller.airSpeed, in: 0.2...3)
                }
                Section("Scrolling") {
                    Toggle("Natural Scrolling", isOn: $controller.naturalScroll)
                    Toggle("Inertial Scrolling", isOn: $controller.inertia)
                }
                Section("Mac Gestures") {
                    Toggle("Pinch to Zoom", isOn: $zoomGesture)
                    Toggle("Two-Finger Double Tap to Fit or Reset Zoom", isOn: $fitGesture)
                    Toggle("Two-Finger Rotation", isOn: $rotateGesture)
                    Toggle("Two-Finger Horizontal Swipe to Navigate", isOn: $pagesGesture)
                    Toggle("Two-Finger Swipe from Right Edge for Notifications", isOn: $notificationsGesture)
                    Toggle("Three-Finger Swipes for Spaces and Windows", isOn: $spacesGesture)
                    Toggle("Four-Finger Pinch for Apps or Spread for Desktop", isOn: $fourGesture)
                    Text("Also applies below the shared display. Page navigation takes over horizontal scrolling. Zoom, rotation and navigation use commands available in the active Mac app.")
                }
                Section("Connection") {
                    Button("Forget Paired Mac", role: .destructive) { controller.stop(); connection.forget(); settings = false }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { settings = false } }
        }
    }

    private var helpView: some View {
        NavigationStack {
            List {
                Section { NavigationLink("Mac Setup Guide") { setupGuide } }
                Section("Trackpad") {
                    Text("Slide one finger to move the pointer. Tap to click, double-tap to double-click, or tap with two fingers to right-click.")
                    Text("Slide two fingers to scroll. To drag, hold Left Click while moving another finger on the trackpad, or tap once and then touch and hold.")
                }
                Section("Air Mouse and Hybrid") {
                    Text("Point the top of your iPhone at the Mac. Hold Move and turn or tilt your phone. Release to adjust your grip. In Hybrid mode, use the trackpad for fine adjustments.")
                    Text("Recenter moves the pointer to the center of its display. Precision slows movement. Continuous keeps motion control active after you release Move.")
                }
                Section("Screen Sharing") {
                    Text("Tap Share next to your Mac to see its desktop above the trackpad. You can keep using the pointer while choosing a display on the Mac. Tap Stop to return to your previous control mode.")
                    Text("The display icon in the top toolbar opens the separate Linked Screen view.")
                }
                Section("Privacy") {
                    Text("Pointer and motion input use Bluetooth. Linked Screen uses an encrypted local network connection to the paired Mac for video, pointer input and text. AirPointer Remote has no account or analytics. Pairing information is stored on your devices. You can remove it in this app’s Settings and in the Mac menu.")
                }
                Section("Stopping Control and Permissions") {
                    Text("Leaving the app or locking iPhone stops control. Use the Mac menu bar to pause, revoke pairings, or quit. The emergency shortcut is Control + Option + Command + Period.")
                    Text("If connected but the pointer does not move, open System Settings → Privacy & Security → Accessibility on the Mac and enable AirPointer Remote.")
                }
            }
            .navigationTitle("How to Use")
            .toolbar { Button("Done") { showHelp = false } }
        }
    }
}
