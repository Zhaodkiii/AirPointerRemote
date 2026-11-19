import AppKit

setvbuf(stdout, nil, _IONBF, 0) // show log lines immediately

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, just the notch
let live = Live()
let receiver = Receiver(live: live)
let notch = NotchController(live: live)
let menu = ReceiverMenu(receiver: receiver)
app.run()
