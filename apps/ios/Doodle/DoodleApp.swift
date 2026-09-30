import SwiftUI

@main
struct DoodleApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .tint(DoodleTheme.pink)
        }
    }
}
