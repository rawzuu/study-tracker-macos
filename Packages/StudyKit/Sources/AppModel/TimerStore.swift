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

    /// Šum, zvonky a notifikace (v testech `nil`).
    @ObservationIgnored public let effects: (any TimerEffects)?

    @ObservationIgnored private let app: AppStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Int
    @ObservationIgnored private var wake: Task<Void, Never>?
    /// Uložený stav chyběl → režim se po načtení dat převezme z nastavení (`defaultMode`).
    @ObservationIgnored private var pristine: Bool
    /// Odkaz, který přišel dřív, než se načetla data (spuštění aplikace odkazem).
    @ObservationIgnored private var pendingLink: TimerLink?
    /// Akce z oznámení, která přišla dřív, než se načetla data (aplikaci spustilo oznámení).
    @ObservationIgnored private var pendingAction: TimerAction?
    /// Poslední uložené sezení – hodnocení z oznámení, když už okno s hodnocením zmizelo.
    @ObservationIgnored private var lastSessionId: String?

    static let stateKey = "st.timer"

    public init(app: AppStore, effects: (any TimerEffects)? = nil, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.app = app
        self.effects = effects
        self.defaults = app.defaults
        self.now = now
        let saved = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(TimerState.self, from: $0) }
        state = saved ?? TimerState(modeId: Schema.defaultSettings.string("defaultMode") ?? "pomodoro")
        pristine = saved == nil
        effects?.setActionHandler { [weak self] action in self?.perform(action) }
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
        if app.phase == .ready, let link = pendingLink {
            pendingLink = nil
            open(link)
        }
        if app.phase == .ready, let action = pendingAction {
            pendingAction = nil
            perform(action)
        }
    }

    /// Tlačítko v oznámení na konci bloku nebo pauzy. Nejdřív dožene konec fáze (oznámení mohlo
    /// přijít, když aplikace spala), pak udělá jen to, co v daném stavu dává smysl.
    public func perform(_ action: TimerAction) {
        guard app.phase == .ready else {
            pendingAction = action
            return
        }
        refresh()
        let onBreak = state.phase != .work
        switch action {
        case .focus(let focus):
            rateLastBlock(focus: focus)
        case .startBreak:
            if onBreak && state.status == .ready { start() }
        case .skipBreak, .startWork:
            if onBreak { skip() }
            if state.phase == .work && state.status == .ready { start() }
        case .endSeries:
            if !onBreak && (state.status == .running || state.status == .paused) { stop() } else { discard() }
        }
    }

    /// Soustředění k právě skončenému bloku (z oznámení) – zavře i okno s hodnocením.
    private func rateLastBlock(focus: Int) {
        guard (1...5).contains(focus) else { return }
        if pendingRating != nil {
            saveRating(focus: focus, recall: "", note: "")
        } else if let id = lastSessionId, var session = app.document.record(Session.self, id: id) {
            session.focus = focus
            app.upsert(session)
        }
    }

    /// Odkaz `studytracker://casovac?start=1…`: spustí blok jako na webu. Běžící blok nepřeruší.
    public func open(_ link: TimerLink) {
        guard app.phase == .ready else {
            pendingLink = link
            return
        }
        let doc = app.document
        let presets = doc.records(TimerPreset.self)
        mutate { s, t, _, _ in
            s.open(link, in: doc, now: t, presets: presets)
            return []
        }
    }

    /// Nastavení šumu se změnilo (i synchronizací z webu) – šum se přizpůsobí hned.
    public func syncEffects() {
        guard app.phase == .ready else { return }
        let t = now()
        updateEffects(at: t)
    }

    /// Ukázka šumu na 5 s; během bloku hraje šum sám.
    public func previewNoise() {
        let s = app.document.settings
        effects?.previewNoise(s.noiseType, volume: s.noiseVolume)
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
        updateEffects(at: t)
    }

    private func updateEffects(at t: Int) {
        let phaseEnd = state.status == .running ? state.nextDeadline(now: t, rules: rules) : nil
        effects?.update(state: state, phaseEnd: phaseEnd, settings: app.document.settings, now: t)
    }

    private func mode(for s: TimerState) -> TimerMode {
        TimerMode.find(s.modeId, presets: app.document.records(TimerPreset.self))
    }

    private func handle(_ events: [TimerEvent], at t: Int) {
        for event in events {
            switch event {
            case .session(let session):
                app.update { $0.saveTimerSession(session, now: t) }
                lastSessionId = session.id
                let s = app.document.settings
                if s.askFocusRating || s.askRecall { pendingRating = session.id }
            case .tooShort:
                notice = "Blok kratší než \(Format.duration(app.document.settings.minSessionSec)) se neukládá"
            case .workEnded, .breakEnded:
                break
            }
            effects?.handle(event, settings: app.document.settings)
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

/// Tlačítka v oznámení na konci bloku a pauzy.
public enum TimerAction: Sendable, Hashable {
    case startBreak, skipBreak, startWork, endSeries
    /// Soustředění 1–5 k bloku, který právě skončil.
    case focus(Int)

    public var identifier: String {
        switch self {
        case .startBreak: "st.startBreak"
        case .skipBreak: "st.skipBreak"
        case .startWork: "st.startWork"
        case .endSeries: "st.endSeries"
        case .focus(let n): "st.focus.\(n)"
        }
    }

    public init?(identifier: String) {
        switch identifier {
        case "st.startBreak": self = .startBreak
        case "st.skipBreak": self = .skipBreak
        case "st.startWork": self = .startWork
        case "st.endSeries": self = .endSeries
        default:
            guard identifier.hasPrefix("st.focus."), let n = Int(identifier.dropFirst("st.focus.".count)), (1...5).contains(n) else { return nil }
            self = .focus(n)
        }
    }

    public var title: String {
        switch self {
        case .startBreak: "Začít pauzu"
        case .skipBreak: "Bez pauzy – další blok"
        case .startWork: "Začít další blok"
        case .endSeries: "Ukončit sérii"
        case .focus(let n): "Soustředění \(n) – \(Format.focusLabels[n].lowercased())"
        }
    }
}
