import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: RemoteController
    @ObservedObject var connection: PhoneConnection
    @StateObject private var sharing = LinkedClient()
    @Environment(\.scenePhase) private var phase
    @State private var inlineRequested = false
    @State private var linkedScreen = false
    @AppStorage("linked.autoPictureInPicture") private var automaticPiP = true
    @State private var settings = false
    @State private var showHelp = false
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
                connectionStatus.padding(.horizontal, inlineWorkspace ? 12 : 0)
                if inlineWorkspace {
                    LinkedWorkspace(client: sharing, inline: true, startPiP: startPiP, automaticPiP: $automaticPiP)
                } else if connection.connected { remote } else { devices }
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
                    Button {
                        if sharing.pipState == .active { sharing.pictureInPicture?.restore(); return }
                        controller.suspendInteraction(true)
                        if sharing.running { connection.send(.init(.linkedInput)) }
                        sharing.hideKeyboard()
                        linkedScreen = true
                    } label: {
                        Image(systemName: "rectangle.connected.to.line.below")
                    }
                    .accessibilityLabel("Linked Screen")
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings")
                }
            }
            .fullScreenCover(isPresented: $linkedScreen, onDismiss: {
                if sharing.pipState == .idle && !sharing.running { inlineRequested = false }
                updateSharingPresentation()
            }) {
                LinkedScreenView(connection: connection, client: sharing, startPiP: startPiP, automaticPiP: $automaticPiP)
            }
            .onAppear {
                let cover = $linkedScreen
                let inline = $inlineRequested
                let preferences = $settings
                let help = $showHelp
                sharing.minimizeForPictureInPicture = {
                    inline.wrappedValue = false
                    cover.wrappedValue = false
                }
                sharing.showPictureInPictureWorkspace = { workspace in
                    preferences.wrappedValue = false
                    help.wrappedValue = false
                    inline.wrappedValue = workspace == .inline
                    cover.wrappedValue = workspace == .linkedScreen
                }
                updateSharingPresentation()
            }
            .onChange(of: linkedScreen) { _, _ in updateSharingPresentation() }
            .onChange(of: sharing.pipState) { _, _ in updateSharingPresentation() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                if sharing.pipState != .idle { sharing.end("Sharing stopped when iPhone locked.", keepDraft: true) }
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
            .onChange(of: settings) { _, _ in updateSharingPresentation() }
            .onChange(of: showHelp) { _, _ in updateSharingPresentation() }
            .onChange(of: connection.connected) { _, _ in sharing.connectionChanged(connection) }
            .onChange(of: connection.macPaused) { _, paused in
                if paused { sharing.end("Control paused on the Mac.") }
            }
            .onChange(of: phase, initial: true) { _, phase in
                sharing.sceneChanged(active: phase == .active, background: phase == .background, controller: controller)
            }
            .sheet(isPresented: $settings) { settingsView }
            .sheet(isPresented: $showHelp) { helpView }
            .confirmationDialog("Replace saved Mac pairing?", isPresented: $confirmNewIdentity, titleVisibility: .visible) {
                Button("Forget and Re-pair", role: .destructive) { connection.retryChangedMac() }
            } message: {
                Text("Only continue if you recognize this Mac. You'll need to compare a new pairing code on both devices.")
            }

        }
    }

    private var inlineWorkspace: Bool {
        inlineRequested && sharing.pipState != .active && !linkedScreen && (sharing.live || sharing.resuming) && !controller.holdingLeft
    }

    private func updateInputOwner() {
        controller.suspendInteraction(linkedScreen || inlineWorkspace || sharing.pipState != .idle || settings || showHelp)
    }

    private func updateSharingPresentation() {
        updateInputOwner()
        if linkedScreen {
            sharing.workspace = .linkedScreen
        } else if inlineWorkspace && !settings && !showHelp {
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
                    .accessibilityLabel("Change shared display")
                } else {
                    Text(inlineRequested && connection.connected ? sharing.status : connection.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if connection.connected {
                Button(action: toggleInlineSharing) {
                    HStack(spacing: 4) {
                        if sharing.running && !sharing.live { ProgressView().controlSize(.small) }
                        else { Image(systemName: sharing.live ? "stop.circle.fill" : "rectangle.on.rectangle") }
                        Text(sharing.running ? (sharing.live ? "Stop" : "Cancel") : "Share")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
                .tint(sharing.live ? .red : .accentColor)
                .disabled(!sharing.running && (controller.paused || connection.macPaused))
                .accessibilityLabel(sharing.running ? "Stop inline screen sharing" : "Share screen on this page")
                Button {
                    if sharing.running { sharing.end(); inlineRequested = false }
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.paused ? "play.fill" : "pause.fill")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(controller.paused ? "Resume Control" : "Pause Control")
            }
        }
    }

    private var devices: some View {
        VStack(spacing: 20) {
            Image(systemName: "cursorarrow.motionlines").font(.system(size: 58)).foregroundStyle(.blue).padding(.top, 40)
            Text("Control Your Mac Pointer").font(.title2.bold())
            Text("Open AirPointer Remote on your Mac. Allow Bluetooth and Accessibility on the Mac, then select it below.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
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
                .padding()
            } else if connection.connecting {
                ProgressView()
                Button("Cancel Connection") { connection.disconnect() }
            } else {
                if connection.changedMac != nil {
                    Button("Forget and Re-pair…") { confirmNewIdentity = true }
                        .buttonStyle(.bordered)
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(connection.nearby) { mac in
                            Button { connection.connect(mac) } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                    Text(mac.name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                        if connection.nearby.isEmpty && connection.bluetoothReady { Text("Looking for nearby Macs…").foregroundStyle(.secondary).padding() }
                        if let installer = MacInstaller.bundled {
                            macSetup(installer)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Open iPhone Settings") {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }.font(.footnote)
        }
    }

    private func macSetup(_ installer: MacInstaller) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Set Up Your Mac", systemImage: "laptopcomputer")
                .font(.headline)
            Text("AirDrop the installer to your Mac, then open it there. Requires macOS 14 or later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShareLink(item: installer, preview: SharePreview("AirPointer Remote for Mac")) {
                Label("Share Mac Installer", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var remote: some View {
        VStack(spacing: 12) {
            Picker("Control Mode", selection: $controller.mode) {
                ForEach(RemoteController.Mode.allCases) { Text($0.rawValue).tag($0) }
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
                    Text(controller.paused || connection.macPaused ? "Control is paused" : controller.mode == .air ? "Hold Move and tilt your iPhone" : "One finger to move · Two to scroll")
                        .font(.headline)
                    Text(controller.mode == .hybrid ? "Hold Move to aim. Release for touch control." : controller.mode == .air ? "Point the top of your iPhone at the Mac." : "Tap to click · Two-finger tap to right-click")
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
                HoldControl(title: "Left Click", enabled: controller.canControl) { controller.left($0, source: "button") }
                if controller.mode != .trackpad {
                    HoldControl(title: controller.airHeld ? "Moving" : "Hold to Move", enabled: controller.canControl) { controller.setAirHeld($0) }
                }
                Button { controller.click(right: true) } label: {
                    Text("Right Click").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).disabled(!controller.canControl)
            }.frame(height: 68)
            HStack {
                HoldControl(title: "Hold for Precision", enabled: controller.canControl) { controller.precise = $0 }
                Button("Disconnect") { controller.stop(); connection.disconnect() }.buttonStyle(.bordered)
            }.frame(height: 44)
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


private struct MacInstaller: Transferable {
    let url: URL

    static var bundled: MacInstaller? {
        Bundle.main.url(forResource: "AirPointer Remote for Mac", withExtension: "dmg")
            .map(MacInstaller.init)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "dmg") ?? .data) { installer in
            SentTransferredFile(installer.url)
        }
    }
}
