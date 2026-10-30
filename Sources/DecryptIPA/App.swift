import SwiftUI

@main
struct DecryptIPAApp: App {
    @StateObject private var deviceStore = DeviceStore()
    @StateObject private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Diagnostics.install()
    }

    var body: some Scene {
        WindowGroup {
            RootScreen()
                .environmentObject(deviceStore)
                .environmentObject(library)
                .onChange(of: scenePhase) { _, phase in
                    Diagnostics.breadcrumb("scenePhase: \(phase)")
                    if phase == .background { Diagnostics.breadcrumb("clean exit") }
                    Diagnostics.flush()
                }
        }
    }
}
