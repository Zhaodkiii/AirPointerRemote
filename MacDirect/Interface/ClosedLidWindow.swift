import AppKit
import SwiftUI

final class ClosedLidWindow {
    static let shared = ClosedLidWindow()
    var openPermissions: ((String?) -> Void)?
    private var window: NSWindow?

    func show() {
        ClosedLidDesktop.shared.refresh()
        if window == nil {
            let controller = NSHostingController(rootView: ClosedLidSettings(desktop: .shared, openPermissions: { [weak self] in self?.openPermissions?($0) }))
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "Closed-Lid Desktop")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ClosedLidSettings: View {
    @ObservedObject var desktop: ClosedLidDesktop
    let openPermissions: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Closed-Lid Desktop", systemImage: "laptopcomputer.and.iphone")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Permissions & Setup…") { openPermissions(nil) }
            }
            Toggle(isOn: Binding(get: { desktop.enabled }, set: desktop.setEnabled)) {
                Text("Enable Lid Desktop for iPhone sharing")
                    .fontWeight(.medium)
            }
            .disabled(desktop.switchingDisplay || (!desktop.supported && !desktop.enabled))
            if !desktop.supported {
                Text("Closed-Lid Desktop needs a MacBook with a detectable lid.")
                    .foregroundStyle(.secondary)
            }
            if !desktop.enabled && desktop.supported && !desktop.active && desktop.message.isEmpty {
                Text("Enable this option to keep controlling your Mac from a paired iPhone when you close the lid. Pair your iPhone by selecting this Mac in GlideCue Remote.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if desktop.enabled && desktop.supported {
                VStack(spacing: 0) {
                    permission("Screen Recording", icon: "display", allowed: desktop.recordingAllowed, button: "Open Settings") {
                        openPermissions("screen")
                    }
                    Divider()
                    permission("Pointer Control", icon: "cursorarrow", allowed: desktop.pointerAllowed, button: "Open Settings") {
                        openPermissions("accessibility")
                    }
                    Divider()
                    permission("Closed-Lid Power", icon: "bolt.circle", allowed: desktop.powerStatus == .enabled,
                               button: desktop.powerStatus == .requiresApproval ? "Approve in Settings" : "Set Up",
                               action: { openPermissions("power") })
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    if !desktop.message.isEmpty {
                        Text(desktop.message)
                    } else if desktop.sharing {
                        Label(desktop.lidClosed ? "Lid Desktop is sharing" : "Ready to close the lid", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if desktop.recordingAllowed && desktop.powerStatus == .enabled {
                        if desktop.sharingAnotherDisplay {
                            Text("Your iPhone is sharing another display. Switch to Lid Desktop before closing the lid.")
                        } else {
                            Text("Keep the lid open and tap Share on your paired iPhone. Close the lid after the iPhone shows Lid Desktop.")
                        }
                    } else {
                        Text("Allow Screen Recording and set up Closed-Lid Power before starting from your iPhone. Restart GlideCue Remote if macOS asks.")
                    }
                    if let warning = desktop.powerWarning {
                        Label(Bundle.main.localizedString(forKey: warning, value: warning, table: nil),
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("Lid Desktop is a separate display. Sharing keeps this Mac awake for up to two hours and ends at 15% battery unless plugged in.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !desktop.enabled && !desktop.message.isEmpty {
                Text(desktop.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if desktop.active {
                    Button("Switch to Built-in Display") { desktop.requestBuiltInDisplay() }
                        .disabled(desktop.switchingDisplay)
                } else if desktop.enabled && desktop.sharingAnotherDisplay {
                    Button("Switch to Lid Desktop") { desktop.requestLidDesktop() }
                        .disabled(!desktop.canSwitchToLidDesktop)
                } else if desktop.powerStatus == .enabled || desktop.powerStatus == .requiresApproval {
                    Button("Remove Power Helper") { desktop.removePowerHelper() }
                }
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permission(_ title: LocalizedStringKey, icon: String, allowed: Bool,
                            button: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Button(button, action: action)
            }
        }
        .frame(minHeight: 42)
    }
}
