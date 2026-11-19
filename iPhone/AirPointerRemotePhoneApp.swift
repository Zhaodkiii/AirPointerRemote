import SwiftUI

@main
struct AirPointerRemotePhoneApp: App {
    @StateObject private var controller = RemoteController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, connection: controller.connection)
                .onChange(of: scenePhase) { _, phase in controller.setForeground(phase == .active, inBackground: phase == .background) }
                .onChange(of: controller.connection.connected) { _, _ in controller.connectionChanged() }
        }
    }
}
