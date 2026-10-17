import Core
import Engine
import Foundation
import Observation

/// Časovač pro celou aplikaci (`TimerProvider` na webu): drží stav, ukládá ho na Mac
/// a hotové bloky zapisuje do dat jako sezení.
///
/// Netiká. Stav jsou jen časové značky; jediné probuzení je naplánované na okamžik dalšího
/// přechodu (konec fáze, ukončení čekající série). Po uspání Macu nebo restartu aplikace
/// `refresh()` dožene, co mezitím proběhlo.
@MainActor
@Observable
public final class TimerStore {
    public private(set) var state: TimerState
    /// Sezení, které po bloku čeká na hodnocení (soustředění, vybavení, poznámka).
    public private(set) var pendingRating: String?
    /// Krátké oznámení pro uživatele (např. že se krátký blok neuložil).
    public var notice: String?

    /// Zvonky a notifikace při přirozeném konci fáze.
    @ObservationIgnored public var onEvent: (TimerEvent) -> Void = { _ in }

    @ObservationIgnored private let app: AppStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Int
    @ObservationIgnored private var wake: Task<Void, Never>?
    /// Uložený stav chyběl → režim se po načtení dat převezme z nastavení (`defaultMode`).
    @ObservationIgnored private var pristine: Bool

    static let stateKey = "st.timer"

    public init(app: AppStore, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.app = app
        self.defaults = app.defaults
        self.now = now
        let saved = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(TimerState.self, from: $0) }
        state = saved ?? TimerState(modeId: Schema.defaultSettings.string("defaultMode") ?? "pomodoro")
        pristine = saved == nil
    }

    // MARK: - Odvozené hodnoty

    public var modes: [TimerMode] { TimerMode.all(presets: app.document.records(TimerPreset.self)) }
    public var mode: TimerMode { TimerMode.find(state.modeId, presets: app.document.records(TimerPreset.self)) }
    public var rules: TimerRules { TimerRules(settings: app.document.settings) }
    public func currentTime() -> Int { now() }

    // MARK: - Ovládání

    public func configure(_ patch: TimerSetup) { mutate { s, _, _, _ in s.configure(patch); return [] } }
    public func setup(_ patch: TimerSetup) { mutate { s, _, _, _ in s.setup(patch); return [] } }
    public func start() { mutate { s, t, mode, _ in s.start(now: t, mode: mode); return [] } }
    public func pause() { mutate { s, t, _, _ in s.pause(now: t); return [] } }
    public func resume() { mutate { s, t, _, _ in s.resume(now: t); return [] } }
    public func addInterruption() { mutate { s, _, _, _ in s.addInterruption(); return [] } }
    public func discard() { mutate { s, _, _, _ in s.discard(); return [] } }
    public func skip() { mutate { s, t, mode, rules in s.skip(now: t, mode: mode, rules: rules) } }

    /// „Hotovo“ – uloží blok a jde na pauzu.
    public func finishWork() { mutate { s, t, mode, rules in s.finishWork(now: t, mode: mode, rules: rules) } }

    /// „Ukončit“ – uloží rozpracovaný blok a ukončí sérii.
    public func stop() { mutate { s, t, _, rules in s.stop(now: t, rules: rules) } }

    /// Mezerník: spustí, pozastaví nebo pokračuje.
    public func toggle() {
        switch state.status {
        case .running: pause()
        case .paused: resume()
        case .idle, .ready: start()
        }
    }

    /// Dožene, co mělo mezitím proběhnout (po startu aplikace, aktivaci okna, probuzení Macu).
    public func refresh() {
        mutate { s, t, mode, rules in s.advance(now: t, mode: mode, rules: rules) }
    }

    // MARK: - Hodnocení po bloku

    /// Uloží hodnocení bloku k sezení; prázdné hodnoty nechají, co tam bylo.
    public func saveRating(focus: Int?, recall: String, note: String) {
        defer { pendingRating = nil }
        guard let id = pendingRating, var session = app.document.record(Session.self, id: id) else { return }
        if let focus { session.focus = focus }
        let recall = recall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recall.isEmpty { session.recall = recall }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { session.note = note }
        app.upsert(session)
    }

    public func skipRating() {
        pendingRating = nil
    }

    // MARK: - Interní

    private func mutate(_ change: (inout TimerState, Int, TimerMode, TimerRules) -> [TimerEvent]) {
        // Než se načtou data, nic se neukládá – blok, který mezitím doběhl, se dožene po načtení.
        guard app.phase == .ready else { return }
        if pristine {
            pristine = false
            if state.status == .idle { state.modeId = app.document.settings.defaultMode }
        }
        let t = now()
        var next = state
        let events = change(&next, t, mode(for: next), rules)
        if next != state {
            state = next
            persist()
        }
        handle(events, at: t)
        schedule(from: t)
    }

    private func mode(for s: TimerState) -> TimerMode {
        TimerMode.find(s.modeId, presets: app.document.records(TimerPreset.self))
    }

    private func handle(_ events: [TimerEvent], at t: Int) {
        for event in events {
            switch event {
            case .session(let session):
                app.update { $0.saveTimerSession(session, now: t) }
                let s = app.document.settings
                if s.askFocusRating || s.askRecall { pendingRating = session.id }
            case .tooShort:
                notice = "Blok kratší než \(Format.duration(app.document.settings.minSessionSec)) se neukládá"
            case .workEnded, .breakEnded:
                break
            }
            onEvent(event)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }

    /// Jediné probuzení na okamžik dalšího přechodu.
    private func schedule(from t: Int) {
        wake?.cancel()
        wake = nil
        guard let deadline = state.nextDeadline(now: t, rules: rules) else { return }
        let delay = max(0, deadline - t)
        wake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay), tolerance: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
