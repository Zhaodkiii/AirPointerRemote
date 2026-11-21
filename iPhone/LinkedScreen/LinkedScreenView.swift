import SwiftUI

struct LinkedScreenView: View {
    @ObservedObject var connection: PhoneConnection
    @ObservedObject var client: LinkedClient
    let startPiP: () -> Void
    @Binding var automaticPiP: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if client.live {
                    LinkedWorkspace(client: client, inline: false, startPiP: startPiP, automaticPiP: $automaticPiP)
                } else {
                    Spacer()
                    Image(systemName: "display").font(.system(size: 48, weight: .light))
                    Text(connection.connected || client.canRetrySharing ? connection.macName : String(localized: "Connect to your Mac first")).font(.headline)
                    Text(client.status).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if client.resumeMac != nil && !connection.connected {
                        Text("Open the Mac lid or wake its external display. Sharing will be requested when the paired Mac reconnects.")
                            .font(.caption).multilineTextAlignment(.center)
                    }
                    if client.running || (client.canRetrySharing && connection.connecting) {
                        ProgressView()
                        Button("Cancel") { client.end() }
                    } else if connection.connected {
                        Toggle("Keep Mac Awake While Sharing", isOn: awakeBinding)
                            .fixedSize()
                        if client.awake {
                            Text("For an external display, connect Mac power and external input devices before closing the lid. If Closed-Lid Desktop is enabled on your Mac, wait for Lid Desktop to appear here.")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal)
                        }
                        Button(client.canRetrySharing ? String(localized: "Resume Sharing") : String(localized: "Start Sharing")) { client.start(connection) }
                            .buttonStyle(.borderedProminent).disabled(connection.macPaused)
                        Button("Choose a Display on the Mac") { client.start(connection, chooseDisplay: true) }
                            .font(.subheadline).disabled(connection.macPaused)
                        if connection.macPaused { Text("Resume pointer control to share.").font(.caption) }
                    } else { Button("Back to Pairing") { dismiss() } }
                    Spacer()
                }
            }
            .navigationTitle(client.live ? client.status : String(localized: "Linked Screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { client.end(); dismiss() } }
                if client.pipState == .active {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Return to Shared Screen", systemImage: "pip.exit") { client.pictureInPicture?.restore() }
                    }
                }
            }
        }
    }

    private var awakeBinding: Binding<Bool> {
        Binding(get: { client.awake }, set: client.setAwake)
    }
}

struct LinkedWorkspace: View {
    @ObservedObject var client: LinkedClient
    let inline: Bool
    let startPiP: () -> Void
    @Binding var automaticPiP: Bool
    @Environment(\.scenePhase) private var phase
    private var direct: Bool { client.directTouch }
    private var fullScreen: Bool { client.fullScreen }
    @State private var leftHeld = false
    private var landscapeFraction: Double { client.previewFraction }
    @State private var initialFraction: Double?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var drag = false
    @State private var zoomRequest: LinkedCanvas.ZoomRequest?
    @State private var hideFullScreenTools = false
    @AppStorage("linked.previewHintSeen") private var previewHintSeen = false
    @State private var showPreviewHint = false
    @State private var showDiagnostics = false
    @State private var confirmDelete = false
    @State private var confirmPaste = false
    @State private var showFieldRequired = false

    var body: some View {
        workspace.safeAreaInset(edge: .bottom, spacing: 0) {
            if client.editing { editor.padding(.vertical, 4) }
        }
        .toolbar {
            if !inline {
                ToolbarItem(placement: .topBarTrailing) { options }
            }
        }
        .onChange(of: phase) { _, phase in
            if phase != .active {
                releaseLeft()
                confirmDelete = false
                confirmPaste = false
            }
        }
        .onChange(of: client.editing) { _, _ in releaseLeft() }
        .onChange(of: direct) { _, _ in
            releaseLeft()
            drag = false
            hideFullScreenTools = false
        }
        .onChange(of: fullScreen) { _, _ in
            releaseLeft()
            hideFullScreenTools = false
            showPreviewHint = false
        }
        .onChange(of: client.previewZoomed) { _, zoomed in
            if zoomed { showPreviewHint = false }
        }
        .task {
            guard !previewHintSeen, !direct, !fullScreen, !client.editing else { return }
            showPreviewHint = true
            previewHintSeen = true
            try? await Task.sleep(for: .seconds(4))
            showPreviewHint = false
        }
        .onChange(of: client.canPoint) { _, enabled in if !enabled { releaseLeft() } }
        .alert("Select an editable Mac field", isPresented: $showFieldRequired) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Click a text field on the shared Mac to use the keyboard.")
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                List {
                    if let metrics = client.diagnostics {
                        Section("Last 60 seconds") {
                            LabeledContent("Player input", value: String(format: "%.1f FPS", metrics.fps))
                            LabeledContent("Displayed frames", value: metrics.displayFPS.map { String(format: "%.1f FPS", $0) } ?? "—")
                            LabeledContent("Longest arrival gap", value: milliseconds(metrics.longestGapMS))
                            LabeledContent("Slowest receive to enqueue", value: milliseconds(metrics.enqueueMS))
                            LabeledContent("Touch round trip (95th percentile)", value: milliseconds(metrics.touchMS))
                        }
                        Section("Latest Mac sample") {
                            if let id = metrics.frameID { LabeledContent("Frame ID", value: String(id)) }
                            LabeledContent("iPhone receive to enqueue", value: milliseconds(metrics.phoneMS))
                            LabeledContent("Encoding", value: milliseconds(metrics.encodeMS))
                            LabeledContent("Send to acknowledgement", value: milliseconds(metrics.ackMS))
                            LabeledContent("Video size", value: metrics.resolution)
                            LabeledContent("Transport") { Text(metrics.split ? "Separate video and control" : "Shared connection") }
                        }
                        Text("A still desktop may produce no new frames. Move a window while comparing connection quality. Touch latency is measured during input.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else { Text("Waiting for video measurements…") }
                }
                .navigationTitle("Stream Diagnostics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { showDiagnostics = false } }
            }
        }
        .onDisappear { releaseLeft() }
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    private var options: some View {
        Menu {
            Toggle("Direct Touch", isOn: $client.directTouch)
            if !direct {
                Button(fullScreen ? String(localized: "Show Trackpad") : String(localized: "Full Screen")) { client.fullScreen.toggle() }
            }
            if direct {
                Toggle("Drag on Display", isOn: $drag)
            }
            if client.pipSupportedByMac && client.pictureInPicture != nil {
                Button("Picture in Picture", systemImage: "pip.enter", action: startPiP)
                    .disabled(!client.pipPossible || client.pipState != .idle)
                Toggle("Start PiP on Home", isOn: $automaticPiP)
            } else if !client.pipSupportedByMac && client.pictureInPicture != nil {
                Text("Update AirPointer on your Mac for Picture in Picture.")
            }
            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                zoomRequest = .init(factor: 1.5)
            }
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                zoomRequest = .init(factor: 1 / 1.5)
            }.disabled(!client.previewZoomed)
            Button("Stream Diagnostics", systemImage: "waveform.path.ecg") { releaseLeft(); showDiagnostics = true }
            if let videoQuality = client.videoQuality { Text(videoQuality) }
            Button("Fit Display") { fitPreview() }.disabled(!client.previewZoomed)
            Button("Click at Pointer") { client.control(.init(.currentClick)) }.disabled(!client.canPoint)
            Button("Right Click at Pointer") { client.control(.init(.currentRight)) }.disabled(!client.canPoint)
            if client.closedLidDesktop {
                Label("Lid Desktop keeps your Mac awake", systemImage: "bolt")
            } else {
                Toggle("Keep Mac Awake", isOn: awakeBinding)
            }
            Button("Stop Sharing", role: .destructive) { client.end() }
        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Sharing options")
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let compact = verticalSizeClass == .compact
            let height = geometry.size.height
            let fitHeight = geometry.size.width * client.size.height / max(1, client.size.width)
            let desiredHeight = compact ? height * landscapeFraction : min(fitHeight, height * 0.62)
            let previewHeight = client.editing
                ? min(fitHeight, desiredHeight + 44, max(0, height - 64))
                : min(desiredHeight, max(height * 0.55, height - 160))
            let hideTools = fullScreen && !direct && hideFullScreenTools && !client.editing
            VStack(spacing: 0) {
                LinkedCanvas(client: client, surface: direct ? .direct : .display,
                             drag: drag, zoomRequest: zoomRequest,
                             onPreviewTap: fullScreen && !client.editing ? { hideFullScreenTools.toggle() } : nil)
                    .frame(maxWidth: .infinity)
                    .frame(height: direct || fullScreen ? nil : previewHeight)
                    .frame(maxHeight: direct || fullScreen ? .infinity : nil)
                    .overlay(alignment: .bottom) {
                        if let warning = client.closedLidPowerWarning, !client.editing {
                            Label(Bundle.main.localizedString(forKey: warning, value: warning, table: nil),
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                .padding(8)
                                .allowsHitTesting(false)
                        } else if client.showCloseLidHint && !client.editing && !client.resuming {
                            Label(client.requiresOpenLid ? "Keep the lid open while sharing the built-in display." : "Ready to close the Mac lid",
                                  systemImage: client.requiresOpenLid ? "laptopcomputer" : "checkmark.circle")
                                .font(.caption.weight(.medium))
                                .padding(8)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                                .allowsHitTesting(false)
                        } else if showPreviewHint && !direct && !fullScreen && !client.editing && !client.resuming {
                            Text("Pinch to zoom")
                                .font(.caption)
                                .padding(8)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if hideTools {
                            screenLayoutButton
                                .padding(.horizontal, 12)
                                .background(.regularMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay {
                        if client.resuming {
                            Label(client.reconnectingTransport ? (client.closedLidDesktop ? "Reconnecting to Lid Desktop…" : "Reconnecting to your Mac…") : "Restoring display…", systemImage: "arrow.clockwise")
                                .padding(8).background(.regularMaterial, in: Capsule())
                        } else if client.videoDelayed {
                            Label("Video delayed. Clicks paused.", systemImage: "hourglass")
                                .font(.subheadline)
                                .padding(8).background(.regularMaterial, in: Capsule())
                                .allowsHitTesting(false)
                        }
                    }
                VStack(spacing: 0) {
                    if !client.editing && !hideTools {
                        HStack(spacing: 8) {
                            if inline { options.frame(width: 44, height: 44) }
                            if client.previewZoomed {
                                Button("Fit", action: fitPreview)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .accessibilityLabel("Fit Display")
                            }
                            if !client.canPoint && !client.videoDelayed {
                                Text("View only").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if compact && !direct && !fullScreen {
                                Capsule().fill(.secondary).frame(width: 38, height: 5)
                                    .frame(width: 84, height: 36).contentShape(Rectangle())
                                    .gesture(DragGesture(coordinateSpace: .global)
                                        .onChanged { value in
                                            let start = initialFraction ?? landscapeFraction
                                            initialFraction = start
                                            client.previewFraction = min(0.70, max(0.25, start + value.translation.height / max(1, height)))
                                        }.onEnded { _ in initialFraction = nil })
                                    .accessibilityLabel("Display height")
                                    .accessibilityAdjustableAction { direction in
                                        client.previewFraction = min(0.70, max(0.25, landscapeFraction + (direction == .increment ? 0.05 : -0.05)))
                                    }
                                Spacer()
                            }
                            if !direct { screenLayoutButton }
                            if client.pipSupportedByMac && client.pictureInPicture != nil {
                                Button(action: startPiP) {
                                    Image(systemName: "pip.enter").frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Picture in Picture")
                                .disabled(!client.pipPossible || client.pipState != .idle)
                            }
                            Button {
                                if client.focus != nil { client.openKeyboard() }
                                else { showFieldRequired = true }
                            } label: {
                                Image(systemName: "keyboard").frame(width: 44, height: 44)
                            }.accessibilityLabel("Keyboard")
                        }.padding(.horizontal, 12)
                    }
                    if !fullScreen && !direct {
                        ZStack {
                            LinkedCanvas(client: client, surface: .trackpad, drag: false)
                            Text("Slide to move · Two fingers to scroll")
                                .font(.footnote).foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 12)
                        if !client.editing {
                            HStack(spacing: 8) {
                                HoldControl(title: String(localized: "Left Click"), enabled: client.canPoint, cancelled: { releaseLeft() }) { down in
                                    if down && !leftHeld {
                                        leftHeld = true
                                        client.control(.init(.currentDown))
                                    } else if !down {
                                        releaseLeft(userClick: true)
                                    }
                                }
                                Button { client.control(.init(.currentRight)) } label: {
                                    Text("Right Click").frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                                .disabled(!client.canPoint)
                            }.frame(height: 44).padding(.horizontal, 12).padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private var screenLayoutButton: some View {
        Button {
            client.fullScreen.toggle()
        } label: {
            Label(fullScreen ? String(localized: "Show Trackpad") : String(localized: "Full Screen"),
                  systemImage: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fitPreview() {
        zoomRequest = nil
        client.fitPreview()
    }

    private func releaseLeft(userClick: Bool = false) {
        guard leftHeld else { return }
        leftHeld = false
        client.releaseLinkedButton(userClick: userClick)
    }

    private var awakeBinding: Binding<Bool> {
        Binding(get: { client.awake }, set: client.setAwake)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let hint = client.editorHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            if client.needsTarget { Button("Use New Field") { client.useNewField() } }
            HStack(alignment: .bottom, spacing: 4) {
                Menu {
                    if client.supportsEditing {
                        Button("Edit Selected Mac Text") { client.loadSelection() }
                            .disabled(!client.draft.isEmpty || client.focus == nil)
                        if client.selectionID != nil {
                            Button("Delete Selected Mac Text", role: .destructive) { confirmDelete = true }
                                .disabled(client.needsTarget || client.focus == nil)
                        }
                    }
                    Button("Cancel Draft", role: .cancel) { client.cancelDraft() }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("Editing options")
                .disabled(client.submitting != nil)
                ZStack(alignment: .topLeading) {
                    if client.draft.isEmpty {
                        Text("Type on Mac…").foregroundStyle(.tertiary).padding(.top, 9).allowsHitTesting(false)
                    }
                    MacDraftEditor(client: client)
                }
                Button { client.hideKeyboard() } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("Hide Keyboard")
                Button {
                    if MacDraftEditor.styles(in: client.richEditor.attributedText).isEmpty { client.insert() }
                    else { confirmPaste = true }
                } label: {
                    Image(systemName: "arrow.up").font(.body.bold()).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(client.canInsert ? Color.accentColor : Color.secondary.opacity(0.45), in: Circle())
                        .frame(width: 44, height: 44)
                }.disabled(!client.canInsert)
                    .accessibilityLabel(client.selectionID == nil ? String(localized: "Insert on Mac") : String(localized: "Replace Mac selection"))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .confirmationDialog("Delete the selected Mac text?", isPresented: $confirmDelete) {
            Button("Delete Selection", role: .destructive) { client.insert(deleting: true) }
        }
        .confirmationDialog("Formatted paste replaces the Mac clipboard.", isPresented: $confirmPaste) {
            Button("Paste Formatted Text") { client.insert() }
        }
    }
}
