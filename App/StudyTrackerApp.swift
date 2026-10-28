import AppIntents
import AppKit
import OSLog
import AppModel
import Core
import Engine
import Features
import SwiftUI
import WidgetData
import WidgetKit

@main
struct StudyTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(MenuBarPanel.shownKey) private var menuBarShown = true
    @AppStorage(MenuBarPanel.timeKey) private var menuBarTime = true

    var body: some Scene {
        // Jedno hlavní okno (jako jedna stránka na webu): odkaz studytracker://… ani znovuotevření
        // nezaloží další. Okno vznikne i při spuštění aplikace odkazem.
        Window("Study Tracker", id: "main") {
            RootView()
                .environment(delegate.store)
                .environment(delegate.timer)
                .environment(delegate.navigator)
                .environment(delegate.toasts)
                .environment(delegate.advisor)
                .environment(delegate.appleCalendar)
                .environment(delegate.anki)
                .environment(delegate.macPrefs)
                .environment(delegate.focus)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 920)
        // Poprvé (než si okno zapamatuje velikost): na notebooku 1440 × 920 (nebo celá menší obrazovka),
        // na velkém monitoru většina obrazovky.
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect.size
            return WindowPlacement(size: CGSize(width: min(screen.width, max(1440, screen.width * 0.82)),
                                                height: min(screen.height, max(920, screen.height * 0.86))))
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

        // Horní lišta: odpočet a ovládání bez otevírání okna (vypíná se v Nastavení).
        // Jen čtení: zápis systému do vazby (při každé aktualizaci ikony) by přes UserDefaults znovu
        // přepočítal scénu a vznikla by nekonečná smyčka (100 % CPU).
        MenuBarExtra(isInserted: Binding(get: { menuBarShown }, set: { _ in })) {
            MenuBarPanel(openPage: { delegate.navigator.page = Page(rawValue: $0) ?? .prehled })
                .environment(delegate.store)
                .environment(delegate.timer)
                .environment(delegate.advisor)
                .preferredColorScheme(delegate.colorScheme)
        } label: {
            MenuBarLabel(showsTime: menuBarTime).environment(delegate.menuBar)
        }
        .menuBarExtraStyle(.window)

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
    /// `-measureTimer <stránka>`: s ukázkovými daty spustí blok a otevře stránku (měření výkonu).
    private static let measurePage: Page? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-measureTimer"), i + 1 < args.count else { return nil }
        return Page(rawValue: args[i + 1])
    }()
    private static let log = Logger(subsystem: "cz.rawzuu.studytracker", category: "odkaz")
    let store = AppStore(environment: uiTesting ? .uiTesting() : .live())
    // UI testy běží potichu – bez šumu, zvonků a notifikací.
    lazy var timer = TimerStore(app: store, effects: Self.uiTesting ? nil : LiveTimerEffects())
    let navigator = Navigator()
    let toasts = Toasts()
    lazy var advisor = Advisor(store: store)
    lazy var menuBar = MenuBarStatus(timer: timer)
    // Widgety: souhrn do sdíleného kontejneru (UI testy bez widgetů) a příkazy z jejich tlačítek.
    lazy var widgets = WidgetBridge(app: store, timer: timer, advisor: advisor, files: Self.uiTesting ? nil : WidgetFiles.shared()) {
        WidgetCenter.shared.reloadAllTimelines()
    }
    // UI testy mají kalendáře v paměti – nikdy nesahají na skutečný Apple Kalendář.
    lazy var appleCalendar = AppleCalendarSync(app: store, service: Self.uiTesting ? DemoCalendars.service() : EventKitCalendarService())
    // Anki na tomto Macu (AnkiConnect); UI testy mají Anki v paměti – nikdy nesahají na skutečnou Anki.
    lazy var anki = Self.uiTesting ? AnkiSync(app: store, service: DemoAnki.service()) : AnkiSync(app: store)
    // Nastavení jen pro tento Mac: automatická pauza, zkratky při bloku, klávesové zkratky, souhrn týdne.
    lazy var macPrefs = MacPreferences(defaults: store.defaults)
    /// Soustředění: v UI testech bez sdíleného kontejneru (nic skutečného se neblokuje ani nečte).
    lazy var focus = Self.uiTesting ? FocusController(files: nil) : FocusController()
    lazy var away = AwayMonitor(timer: timer, prefs: macPrefs)
    lazy var automation = BlockAutomation(timer: timer, prefs: macPrefs)
    lazy var weekly = WeeklySummaryNotifier(app: store, prefs: macPrefs) { [timer] text in
        timer.effects?.notify(id: "study-weekly", title: text.title, body: text.body, url: URL(string: "studytracker://statistiky"))
    }
    lazy var hotKeys = HotKeyCenter { [weak self] action in self?.hotKey(action) }
    // Úspěchy: nově získané se uloží do dat a krátce se o nich dá vědět.
    lazy var achievements = AchievementWatcher(app: store, toasts: toasts) { [navigator] in navigator.page = .uspechy }
    private var wakeObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Příjemce tlačítek v oznámení musí existovat dřív, než systém předá odpověď –
        // aplikaci mohlo spustit právě tlačítko v oznámení (akce počká na načtení dat).
        _ = timer
        // Zkratky a Siri: akce dostanou stejný stav aplikace jako okno.
        let store = store, timer = timer, advisor = advisor
        let actions = StudyActionsProvider { StudyActions(store: store, timer: timer, advisor: advisor) }
        AppDependencyManager.shared.add(dependency: actions)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Data se načítají hned po spuštění, nezávisle na okně (i když aplikaci spustí odkaz).
        Task {
            await store.start()
            // Blok, který doběhl, zatímco aplikace neběžela, se uloží až teď; čekající odkaz se spustí.
            timer.refresh()
            // Widgety dostanou souhrn a začnou se poslouchat jejich tlačítka.
            widgets.start()
            // Apple Kalendář: zápis plánu (když je zapnutý) a obsazený čas z ostatních kalendářů.
            await appleCalendar.start()
            // Anki: jen když je na tomto Macu zapnutá.
            anki.start()
            achievements.start()
            // V UI testech bez sledování nečinnosti, zkratek a oznámení – testy běží potichu.
            if !Self.uiTesting {
                away.start()
                automation.start()
                weekly.start()
                applyHotKeys()
                focus.start()
            }
            // Měření výkonu s běžícím blokem (Tools/dev/idle-cpu.sh casovac) – jen s ukázkovými daty.
            if Self.uiTesting, let page = Self.measurePage {
                timer.configure(TimerSetup(subjectId: "demo-anat", topic: "Lebka"))
                timer.start()
                navigator.page = page
            }
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
        // Tlačítko widgetu, když aplikace neběžela: příkaz se provede po načtení dat.
        for url in urls {
            guard let command = WidgetCommand(url: url, at: store.nowMs) else { continue }
            widgets.open(command)
        }
        // Odkaz na stránku (klepnutí na widget): studytracker://prehled, …/planovac…
        for url in urls where url.scheme?.lowercased() == TimerLink.scheme && url.query == nil {
            if let page = Page(rawValue: url.host ?? "") { navigator.page = page }
        }
        // Odkaz z události v Apple Kalendáři: kalendář na týdnu bloku nebo zkoušky.
        for url in urls {
            guard let key = CalendarMirror.Key(url: url) else { continue }
            navigator.page = .planovac
            navigator.calendarFocus = CalendarFocus(day: focusDay(key) ?? store.nowMs)
        }
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

    /// Téma ze synchronizovaného nastavení (výchozí tmavé, jako na webu) – i pro okénko z horní lišty.
    var colorScheme: ColorScheme? {
        switch store.document.settings.theme {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    private func focusDay(_ key: CalendarMirror.Key) -> Int? {
        switch key.kind {
        case .block: store.document.record(PlanBlock.self, id: key.id)?.start
        case .exam: store.document.record(Exam.self, id: key.id).flatMap { store.clock.parseDayKey($0.date) }
        }
    }

    /// Zaregistruje klávesové zkratky a po každé změně v Nastavení znovu.
    private func applyHotKeys() {
        observeHotKeys()
    }

    private func observeHotKeys() {
        withObservationTracking {
            macPrefs.hotKeyConflicts = Set(hotKeys.set([.toggle: macPrefs.toggleHotKey, .show: macPrefs.showHotKey]))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHotKeys() }
        }
    }

    /// Klávesová zkratka odkudkoli: spustit, pozastavit nebo pokračovat; otevřít okno.
    private func hotKey(_ action: HotKeyCenter.Action) {
        switch action {
        case .toggle:
            timer.refresh()
            switch timer.state.status {
            case .running: timer.pause()
            case .paused: timer.resume()
            case .idle, .ready:
                let actions = StudyActions(store: store, timer: timer, advisor: advisor)
                // Bez předmětu (nebo dat) zkratka otevře časovač, ať je vidět proč.
                if (try? actions.start(subjectId: nil, topic: nil, modeId: nil)) == nil { show(.casovac) }
            }
        case .show:
            show(navigator.page ?? .prehled)
        }
    }

    /// Okno dopředu na stránce `page` (odkaz okno vytvoří, i když bylo zavřené).
    private func show(_ page: Page) {
        if let url = URL(string: "\(TimerLink.scheme)://\(page.rawValue)") { NSWorkspace.shared.open(url) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        timer.refresh()
        anki.refreshIfDue()
        if !Self.uiTesting { weekly.check() }
        Task { await store.setActive(true) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { await store.setActive(false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Tlačítka ve widgetech pak aplikaci otevřou odkazem.
        widgets.markStopped()
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
    /// Týden, který má Kalendář ukázat (odkaz z Apple Kalendáře).
    var calendarFocus: CalendarFocus?
}
