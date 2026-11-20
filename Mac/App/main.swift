import AppKit

setvbuf(stdout, nil, _IONBF, 0) // show log lines immediately

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, just the notch
#if CLOSED_LID_DESKTOP
let standardBundleID = "com.daokaihua.airpointerremote"
if NSRunningApplication.runningApplications(withBundleIdentifier: standardBundleID)
    .contains(where: { $0.executableURL?.lastPathComponent == "AirPointerRemoteMac" && !$0.isTerminated }) {
    let alert = NSAlert()
    alert.messageText = String(localized: "Another AirPointer receiver is open")
    alert.informativeText = String(localized: "Quit AirPointer Remote from its menu bar, then reopen AirPointer Remote Direct so your iPhone connects to the correct receiver.")
    alert.addButton(withTitle: String(localized: "Quit AirPointer Remote Direct"))
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(0)
}
#endif
let live = Live()
let receiver = Receiver(live: live)
let notch = NotchController(live: live)
let menu = ReceiverMenu(receiver: receiver)
#if CLOSED_LID_DESKTOP
_ = ClosedLidDesktop.shared
#endif
app.run()
