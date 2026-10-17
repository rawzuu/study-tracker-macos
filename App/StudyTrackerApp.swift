import AppKit
import AppModel
import Features
import SwiftUI

@main
struct StudyTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Study Tracker", id: "main") {
            RootView()
                .environment(delegate.store)
                .frame(minWidth: 900, minHeight: 600)
                .task { await delegate.store.start() }
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandMenu("Data") {
                Button("Synchronizovat teď") { Task { await delegate.store.syncNow() } }
                    .keyboardShortcut("r")
                    .disabled(!delegate.store.isConnected)
            }
        }

        Settings {
            ScrollView {
                SyncSettingsView().padding(28)
            }
            .frame(width: 780, height: 560)
            .environment(delegate.store)
        }
    }
}

/// Životní cyklus aplikace: aktivní okno řídí pravidelnou synchronizaci, před ukončením
/// se data uloží a neodeslané změny odešlou.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore(environment: ProcessInfo.processInfo.arguments.contains("-uiTesting") ? .uiTesting() : .live())

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await store.setActive(true) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { await store.setActive(false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = store
        Task {
            // Ukončení nesmí viset na síti – nejvýš 5 s, data jsou stejně uložená na Macu.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await store.prepareForTermination() }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
