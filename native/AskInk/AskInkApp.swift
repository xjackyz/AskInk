import SwiftUI

@main
struct AskInkApp: App {
    @StateObject private var store = ReaderStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ReaderScreen().environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    store.setAutomaticActive(phase == .active)
                    if phase != .active { store.flush() }
                }
        }
    }
}
