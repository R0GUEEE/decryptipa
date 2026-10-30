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
            RootView()
                .environmentObject(deviceStore)
                .environmentObject(library)
                .onAppear { library.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    Diagnostics.breadcrumb("scenePhase: \(phase)")
                    if phase != .active { Diagnostics.flush() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            DecryptView()
                .tabItem { Label("Decrypt", systemImage: "lock.open.display") }
                .tag(0)

            DevicesView()
                .tabItem { Label("Devices", systemImage: "iphone.gen3") }
                .tag(1)

            LibraryView()
                .tabItem { Label("Library", systemImage: "folder") }
                .tag(2)
        }
    }
}
