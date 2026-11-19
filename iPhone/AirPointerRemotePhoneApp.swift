import SwiftUI

@main
struct AirPointerRemotePhoneApp: App {
    @StateObject private var controller = RemoteController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, connection: controller.connection)
                .onChange(of: controller.connection.connected) { _, _ in controller.connectionChanged() }
        }
    }
}
