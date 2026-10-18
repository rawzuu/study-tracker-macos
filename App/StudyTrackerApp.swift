import AppKit
import OSLog
import AppModel
import Engine
import Features
import SwiftUI

@main
struct StudyTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Jedno hlavní okno (jako jedna stránka na webu): odkaz studytracker://… ani znovuotevření
        // nezaloží další. Okno vznikne i při spuštění aplikace odkazem.
        Window("Study Tracker", id: "main") {
            RootView()
                .environment(delegate.store)
                .environment(delegate.timer)
                .environment(delegate.navigator)
                .environment(delegate.toasts)
                .environment(delegate.calendarFeed)
                .environment(delegate.advisor)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 920)
        // Poprvé (než si okno zapamatuje velikost) zabere většinu obrazovky – na velkém monitoru tedy víc než na notebooku.
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect.size
            return WindowPlacement(size: CGSize(width: min(max(screen.width * 0.82, 1000), 2400),
                                                height: min(max(screen.height * 0.86, 640), 1500)))
        }
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
    private static let uiTesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
    private static let log = Logger(subsystem: "cz.rawzuu.studytracker", category: "odkaz")
    let store = AppStore(environment: uiTesting ? .uiTesting() : .live())
    // UI testy běží potichu – bez šumu, zvonků a notifikací.
    lazy var timer = TimerStore(app: store, effects: Self.uiTesting ? nil : LiveTimerEffects())
    let navigator = Navigator()
    let toasts = Toasts()
    lazy var calendarFeed = CalendarFeedSync(app: store)
    lazy var advisor = Advisor(store: store)
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Data se načítají hned po spuštění, nezávisle na okně (i když aplikaci spustí odkaz).
        Task {
            await store.start()
            // Blok, který doběhl, zatímco aplikace neběžela, se uloží až teď; čekající odkaz se spustí.
            timer.refresh()
            // Odebíraný kalendář se aktualizuje po změnách plánu (jen když je zapnutý).
            calendarFeed.start()
        }
        // Po probuzení Macu dohnat konec bloku nebo pauzy, který proběhl ve spánku.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer.refresh() }
        }
    }

    /// `studytracker://casovac…` – otevře časovač a s `start=1` rovnou spustí blok.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where TimerLink.isTimerPage(url) {
            navigator.page = .casovac
            guard let link = TimerLink(url: url) else { continue }
            let before = timer.state.status
            timer.open(link)
            // Bez názvů předmětů a témat – jen co se stalo.
            Self.log.notice("Odkaz na časovač: \(before.rawValue, privacy: .public) → \(self.timer.state.status.rawValue, privacy: .public)")
        }
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        timer.refresh()
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

/// Která stránka je otevřená – sdílené, aby ji mohl přepnout i odkaz.
@MainActor
@Observable
final class Navigator {
    var page: Page? = .prehled
}
