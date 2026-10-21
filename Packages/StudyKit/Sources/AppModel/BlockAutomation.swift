import AppKit
import Engine

/// Vlastní zkratky ze Zkratek na začátku a konci bloku učení (volitelné, jen na tomto Macu) – třeba
/// zapnout a vypnout Nerušit, pustit hudbu, zavřít chat. Pozastavení bloku se nepočítá jako konec.
@MainActor
public final class BlockAutomation {
    private let timer: TimerStore
    private let prefs: MacPreferences
    private let run: @MainActor (String) -> Void
    private var inBlock: Bool
    private var started = false

    public init(timer: TimerStore, prefs: MacPreferences, run: @escaping @MainActor (String) -> Void = BlockAutomation.runShortcut) {
        self.timer = timer
        self.prefs = prefs
        self.run = run
        inBlock = timer.state.isStudying
    }

    public func start() {
        guard !started else { return }
        started = true
        inBlock = timer.state.isStudying
        observeChanges({ [weak self] in _ = self?.timer.state }, react: { [weak self] in self?.update() })
    }

    func update() {
        let now = timer.state.isStudying
        guard now != inBlock else { return }
        inBlock = now
        guard prefs.shortcutsEnabled else { return }
        let name = (now ? prefs.startShortcut : prefs.endShortcut).trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { run(name) }
    }

    /// Spustí zkratku podle názvu na pozadí (Zkratky se nepřepnou dopředu).
    public static func runShortcut(_ name: String) {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = c.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config)
    }

    /// Otevře aplikaci Zkratky (založení zkratky).
    public static func openShortcutsApp() {
        if let url = URL(string: "shortcuts://") { NSWorkspace.shared.open(url) }
    }
}

/// Pondělní souhrn minulého týdne do oznámení – jednou za týden, od pondělí 8:00, když aplikace běží
/// (v pozdější den týdne, pokud v pondělí neběžela). Kliknutí otevře Statistiky.
@MainActor
public final class WeeklySummaryNotifier {
    private let app: AppStore
    private let prefs: MacPreferences
    private let post: @MainActor (WeeklySummary.Text) -> Void
    private var hourly: Task<Void, Never>?

    static let sentKey = "st.weekly.sent"
    static let notificationId = "study-weekly"

    public init(app: AppStore, prefs: MacPreferences, post: @escaping @MainActor (WeeklySummary.Text) -> Void) {
        self.app = app
        self.prefs = prefs
        self.post = post
    }

    public func start() {
        check()
        hourly = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                self?.check()
            }
        }
    }

    /// Po aktivaci aplikace a jednou za hodinu.
    public func check() {
        guard prefs.weeklySummary, app.phase == .ready else { return }
        let now = app.nowMs, clock = app.clock
        let week = clock.dayKey(WeeklySummary.week(now: now, clock: clock))
        // Až od pondělí 8:00 – ráno, ne o půlnoci.
        guard now >= clock.startOfWeek(now) + 8 * 3_600_000, app.defaults.string(forKey: Self.sentKey) != week else { return }
        app.defaults.set(week, forKey: Self.sentKey)
        if let text = WeeklySummary.make(app.document, now: now, clock: clock) { post(text) }
    }
}
