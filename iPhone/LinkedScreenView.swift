import SwiftUI

struct LinkedScreenView: View {
    @ObservedObject var connection: PhoneConnection
    @StateObject private var client = LinkedClient()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var direct = true
    @State private var drag = false
    @State private var reset = 0
    @FocusState private var keyboard: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if client.live {
                    LinkedCanvas(client: client, direct: direct, drag: drag, reset: reset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if client.editing { editor }
                    else {
                        HStack {
                            Picker("Pointer mode", selection: $direct) {
                                Text("Direct").tag(true)
                                Text("Trackpad").tag(false)
                            }.pickerStyle(.segmented)
                            Button { drag.toggle() } label: { Image(systemName: "hand.draw") }
                                .accessibilityLabel(drag ? "Disable drag" : "Enable drag")
                                .buttonStyle(.bordered).tint(drag ? .accentColor : .secondary)
                            Button { client.openKeyboard(); keyboard = true } label: { Image(systemName: "keyboard") }
                                .buttonStyle(.bordered).accessibilityLabel("Keyboard")
                        }.padding(.horizontal)
                        Text(!client.canPoint ? "View only · Check Accessibility on the Mac." :
                                drag ? "Slide one finger to drag. Lift to release." :
                                direct ? "Tap to click · Hold for right click · Pinch to zoom" :
                                "Slide to move · Tap to click · Two fingers to scroll")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Spacer()
                    Image(systemName: "display").font(.system(size: 48, weight: .light))
                    Text(connection.connected ? connection.macName : "Connect to your Mac first").font(.headline)
                    Text(client.status).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if client.resumeMac != nil && !connection.connected {
                        Text("Open the Mac lid or wake its external display. Sharing will be requested when the paired Mac reconnects.")
                            .font(.caption).multilineTextAlignment(.center)
                    }
                    if client.running {
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
                        Button("Start Sharing") { client.start(connection) }
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
                if client.live {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Fit Display") { reset += 1 }
                            Button("Click at Pointer") { client.control(.init(.currentClick)) }.disabled(!client.canPoint)
                            Button("Right Click at Pointer") { client.control(.init(.currentRight)) }.disabled(!client.canPoint)
                            Toggle("Keep Mac Awake", isOn: awakeBinding)
                            Button("Stop Sharing", role: .destructive) { client.end() }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Sharing options")
                    }
                }
            }
        }
        .onChange(of: client.editing) { _, edit in keyboard = edit }
        .onChange(of: connection.connected) { _, _ in client.connectionChanged(connection) }
        .onChange(of: connection.macPaused) { _, paused in if paused { client.end("Control paused on the Mac.") } }
        .onChange(of: phase) { _, phase in if phase == .background { client.end() } }
        .onDisappear { client.end() }
    }

    private var awakeBinding: Binding<Bool> {
        Binding(get: { client.awake }, set: client.setAwake)
    }

    private var editor: some View {
        VStack(alignment: .leading) {
            TextField("Type for the selected Mac field", text: $client.draft, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder).focused($keyboard)
                .disabled(client.submitting != nil).onAppear { keyboard = true }
            HStack {
                Button("Cancel") { client.cancelDraft() }.disabled(client.submitting != nil)
                Spacer()
                if client.needsTarget { Button("Use New Field") { client.openKeyboard() } }
                else if client.focus == nil { Text("Select an editable Mac field.").font(.caption) }
                Button("Insert") { client.insert() }.disabled(!client.canInsert)
            }
        }.padding(.horizontal)
    }
}
