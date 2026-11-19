import SwiftUI

struct LinkedScreenView: View {
    @ObservedObject var connection: PhoneConnection
    @ObservedObject var client: LinkedClient
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if client.live {
                    LinkedWorkspace(client: client, inline: false)
                } else {
                    Spacer()
                    Image(systemName: "display").font(.system(size: 48, weight: .light))
                    Text(connection.connected || client.canRetrySharing ? connection.macName : "Connect to your Mac first").font(.headline)
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
                            Text("To close the lid, connect power and an external keyboard, mouse and display. Choose that display when sharing.")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal)
                        }
                        Button(client.canRetrySharing ? "Resume Sharing" : "Start Sharing") { client.start(connection) }
                            .buttonStyle(.borderedProminent).disabled(connection.macPaused)
                        if connection.macPaused { Text("Resume pointer control to share.").font(.caption) }
                    } else { Button("Back to Pairing") { dismiss() } }
                    Spacer()
                }
            }
            .navigationTitle(client.live ? client.status : "Linked Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { client.end(); dismiss() } }
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
    @Environment(\.scenePhase) private var phase
    @State private var direct = false
    @State private var fullScreen = false
    @State private var leftHeld = false
    @State private var landscapeFraction = 0.50
    @State private var initialFraction: Double?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var drag = false
    @State private var reset = 0
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
        .onChange(of: direct) { _, _ in releaseLeft(); drag = false }
        .onChange(of: fullScreen) { _, _ in releaseLeft() }
        .onChange(of: client.canPoint) { _, enabled in if !enabled { releaseLeft() } }
        .alert("Select an editable Mac field", isPresented: $showFieldRequired) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Click a text field on the shared Mac to use the keyboard.")
        }
        .onDisappear { releaseLeft() }
    }

    private var options: some View {
        Menu {
            Toggle("Direct Touch", isOn: $direct)
            if !direct { Toggle("Full Screen", isOn: $fullScreen) }
            if direct {
                Toggle("Drag on Display", isOn: $drag)
            }
            Button("Fit Display") { reset += 1 }
            Button("Click at Pointer") { client.control(.init(.currentClick)) }.disabled(!client.canPoint)
            Button("Right Click at Pointer") { client.control(.init(.currentRight)) }.disabled(!client.canPoint)
            Toggle("Keep Mac Awake", isOn: awakeBinding)
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
            VStack(spacing: 0) {
                LinkedCanvas(client: client, surface: direct ? .direct : .display,
                             drag: drag, reset: reset)
                    .frame(maxWidth: .infinity)
                    .frame(height: direct || fullScreen ? nil : previewHeight)
                    .frame(maxHeight: direct || fullScreen ? .infinity : nil)
                    .overlay {
                        if client.resuming {
                            Label("Restoring display…", systemImage: "arrow.clockwise")
                                .padding(8).background(.regularMaterial, in: Capsule())
                        }
                    }
                VStack(spacing: 0) {
                    if !client.editing {
                        HStack {
                            if inline { options.frame(width: 44, height: 44) }
                            if !client.canPoint {
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
                                            landscapeFraction = min(0.70, max(0.25, start + value.translation.height / max(1, height)))
                                        }.onEnded { _ in initialFraction = nil })
                                    .accessibilityLabel("Display height")
                                    .accessibilityAdjustableAction { direction in
                                        landscapeFraction = min(0.70, max(0.25, landscapeFraction + (direction == .increment ? 0.05 : -0.05)))
                                    }
                                Spacer()
                            }
                            if !direct {
                                Button { fullScreen.toggle() } label: {
                                    Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                        .frame(width: 44, height: 44)
                                }.accessibilityLabel(fullScreen ? "Exit Full Screen" : "Full Screen")
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
                            LinkedCanvas(client: client, surface: .trackpad, drag: false, reset: 0)
                            Text("Slide to move · Two fingers to scroll")
                                .font(.footnote).foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 12)
                        if !client.editing {
                            HStack(spacing: 8) {
                                HoldControl(title: "Left Click", enabled: client.canPoint, cancelled: { releaseLeft() }) { down in
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
                    .accessibilityLabel(client.selectionID == nil ? "Insert on Mac" : "Replace Mac selection")
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
