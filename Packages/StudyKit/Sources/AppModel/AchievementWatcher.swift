import Core
import Engine
import Foundation
import Observation

/// Hlídá nově odemčené úspěchy (`AchievementWatcher` na webu): uloží je natrvalo do dat (aby je pozdější
/// změna cílů nevzala) a krátce o nich dá vědět. Při prvním spuštění na tomto Macu jen tiše uloží stav.
/// Počítá se s prodlevou po změně dat – rychlé úpravy za sebou stačí vyhodnotit jednou.
@MainActor
public final class AchievementWatcher {
    private let app: AppStore
    private let toasts: Toasts?
    private let open: @MainActor () -> Void
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var started = false

    static let seenKey = "st.ach.seen"

    public init(app: AppStore, toasts: Toasts?, delay: Duration = .seconds(1), open: @escaping @MainActor () -> Void) {
        self.app = app
        self.toasts = toasts
        self.delay = delay
        self.open = open
    }

    /// Po načtení dat: vyhodnotí hned a pak po každé změně dat.
    public func start() {
        guard !started else { return }
        started = true
        check()
        observe()
    }

    /// Vyhodnotí úspěchy, nové uloží do dat a o čerstvě získaných dá vědět.
    func check() {
        guard app.phase == .ready else { return }
        let doc = app.document, now = app.nowMs
        let res = Achievements.evaluate(doc, now: now, clock: app.clock)
        let pending = Achievements.toPersist(doc, res, now: now)
        if !pending.isEmpty { app.update { $0.upsert(pending, now: now) } }

        let ids = res.unlockedIds
        let seen = app.defaults.stringArray(forKey: Self.seenKey)
        app.defaults.set(ids, forKey: Self.seenKey)
        guard let seen else { return }
        let known = Set(seen)
        let fresh = ids.filter { !known.contains($0) }
        guard let last = fresh.last, let d = Achievements.describe(last) else { return }
        let more = fresh.count > 1 ? " (+\(fresh.count - 1) další)" : ""
        toasts?.show("Odemčeno: \(d.name) – \(d.desc)\(more)", action: "Zobrazit") { [open] in open() }
    }

    private func observe() {
        observeChanges({ [weak self] in _ = self?.app.document }, react: { [weak self] in self?.schedule() })
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }
}
