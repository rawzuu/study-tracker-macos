import SwiftUI

@main
struct StudyTrackerApp: App {
    var body: some Scene {
        WindowGroup("Study Tracker", id: "main") {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)

        Settings {
            Text("Nastavení přijde v milníku M6.")
                .padding(40)
        }
    }
}
