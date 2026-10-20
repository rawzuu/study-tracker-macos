import Core
import Engine
import Foundation
import Networking
import Observation

/// Synchronizace s Anki (`useAnkiSync.ts` na webu): každé 2 minuty a po návratu do aplikace načte z Anki
/// na tomto Macu počty k opakování a z historie opakování udělá sezení (`AnkiImport`). Zapisuje jen při
/// skutečné změně, takže se zbytečně necommituje na GitHub.
///
/// Zapnutí je jen pro tento Mac (UserDefaults) – sdílené nastavení `anki.enabled` patří webu a Mac ho
/// nemění, aby se po instalaci nezačalo nic zapisovat bez vědomí uživatele. Sdílené jsou jen volby, jak
/// čas z Anki počítat (`countTime`, `importDays`, přiřazení balíčků k předmětům).
@MainActor
@Observable
public final class AnkiSync {
    public enum Status: Equatable, Sendable {
        case off
        case syncing
        case ok(at: Int)
        case failed(AnkiConnectError, at: Int)
    }

    public private(set) var status: Status = .off
    public private(set) var enabled: Bool

    @ObservationIgnored private let app: AppStore
    @ObservationIgnored private let service: any AnkiConnecting
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var lastRun = 0
    /// Kolik karet bylo dnes hotovo při minulém načtení – když se nezmění, historie se nestahuje znovu.
    @ObservationIgnored private var lastSeen: (day: Int, reviewedToday: Int)?

    static let enabledKey = "st.anki.mac"

    public init(app: AppStore, service: any AnkiConnecting, interval: Duration = .seconds(120)) {
        self.app = app
        self.service = service
        self.interval = interval
        enabled = app.defaults.bool(forKey: Self.enabledKey)
    }

    /// Skutečná Anki na tomto Macu (AnkiConnect na 127.0.0.1:8765).
    public convenience init(app: AppStore) {
        self.init(app: app, service: AnkiConnectClient())
    }

    /// Po načtení dat: když je Anki na tomto Macu zapnutá, načte ji hned a pak každé 2 minuty.
    public func start() {
        if enabled { schedule() }
    }

    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        app.defaults.set(on, forKey: Self.enabledKey)
        if on {
            schedule()
        } else {
            loop?.cancel()
            loop = nil
            status = .off
        }
    }

    /// Po návratu do aplikace (jako `visibilitychange` na webu) – nejvýš jednou za 20 s.
    public func refreshIfDue() {
        guard enabled, app.nowMs - lastRun > 20_000 else { return }
        Task { await syncNow() }
    }

    /// Načíst teď. `fullHistory` = přepočítat celou historii (`importDays`), třeba po změně přiřazení balíčků.
    public func syncNow(fullHistory: Bool = false) async {
        guard enabled, !running, app.phase == .ready else { return }
        running = true
        defer { running = false }
        lastRun = app.nowMs
        status = .syncing
        let doc = app.document, clock = app.clock, now = app.nowMs
        let since = AnkiImport.since(doc, fullHistory: fullHistory, now: now, clock: clock)
        let day = clock.startOfDay(now)
        let known = !fullHistory && lastSeen?.day == day ? lastSeen?.reviewedToday : nil
        do {
            let result = try await service.fetch(since: AnkiImport.fetchFrom(since: since, clock: clock), knownReviewedToday: known)
            let fetch = AnkiImport.Fetch(
                decks: result.decks.map { AnkiDeckStat(name: $0.name, newCount: $0.newCount, learnCount: $0.learnCount, reviewCount: $0.reviewCount, total: $0.total) },
                reviewedToday: result.reviewedToday,
                reviews: result.reviews.map { AnkiImport.Review(deck: $0.deck, time: $0.time, durationMs: $0.durationMs) },
                reviewsFetched: result.reviewsFetched
            )
            // Data se mohla během načítání změnit – změny se počítají až z aktuální verze.
            let changes = AnkiImport.changes(app.document, fetch: fetch, since: since, now: app.nowMs, clock: clock)
            if !changes.isEmpty { apply(changes) }
            lastSeen = (day, result.reviewedToday)
            status = .ok(at: app.nowMs)
        } catch {
            status = .failed(error, at: app.nowMs)
        }
    }

    /// Nastavení výpočtu (sdílené s webem); po změně přiřazení se historie přepočítá.
    public func updateSettings(recompute: Bool = false, _ change: (inout AnkiSettings) -> Void) {
        app.updateSettings { s in
            var anki = s.anki
            change(&anki)
            s.anki = anki
        }
        if recompute { Task { await syncNow(fullHistory: true) } }
    }

    // MARK: - Interní

    private func schedule() {
        loop?.cancel()
        loop = Task { [weak self, interval] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func apply(_ changes: AnkiImport.Changes) {
        let now = app.nowMs
        app.update { doc in
            if let snapshot = changes.snapshot { doc.upsert(snapshot, now: now) }
            if let subject = changes.subject { doc.upsert(subject, now: now) }
            if !changes.sessions.isEmpty { doc.upsert(changes.sessions, now: now) }
            for id in changes.remove { doc.remove(.sessions, id: id, now: now) }
        }
    }
}

/// Anki v paměti – pro testy, UI testy a náhledy (nikdy skutečná Anki).
public actor InMemoryAnki: AnkiConnecting {
    public var result: AnkiConnectResult
    public var error: AnkiConnectError?
    public private(set) var calls: [(since: Int, known: Int?)] = []

    public init(result: AnkiConnectResult, error: AnkiConnectError? = nil) {
        self.result = result
        self.error = error
    }

    public func fetch(since: Int, knownReviewedToday: Int?) async throws(AnkiConnectError) -> AnkiConnectResult {
        calls.append((since, knownReviewedToday))
        if let error { throw error }
        if let knownReviewedToday, knownReviewedToday == result.reviewedToday {
            return AnkiConnectResult(decks: result.decks, reviewedToday: result.reviewedToday, reviews: [], reviewsFetched: false)
        }
        return result
    }

    public func set(_ result: AnkiConnectResult) { self.result = result }
    public func fail(_ error: AnkiConnectError?) { self.error = error }
}

/// Ukázková Anki pro UI testy a náhledy: dva balíčky a dnešní opakování z Anatomie.
public enum DemoAnki {
    public static func service(now: Int = Int(Date().timeIntervalSince1970 * 1000)) -> InMemoryAnki {
        let start = now - 90 * StudyClock.minute
        return InMemoryAnki(result: AnkiConnectResult(
            decks: [
                AnkiConnectDeck(name: "Anatomie", newCount: 12, learnCount: 3, reviewCount: 48, total: 1240),
                AnkiConnectDeck(name: "Latina", newCount: 5, learnCount: 0, reviewCount: 17, total: 320),
            ],
            reviewedToday: 64,
            reviews: (0..<64).map { AnkiConnectReview(deck: "Anatomie", time: start + $0 * 12_000, durationMs: 11_000) },
            reviewsFetched: true
        ))
    }
}
