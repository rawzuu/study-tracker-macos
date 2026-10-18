import Core
import Engine
import Foundation
import Observation

/// „Co teď?“ pro všechna okna (`useRecommendations` na webu). Doporučení se přepočítají při změně dat
/// a jinak nejvýš jednou za 5 minut, aby se neměnila pod rukama; Přehled i Časovač tak ukazují totéž.
///
/// Drží i ranní výzvu k naplánování dne – její skrytí platí jen pro dnešek a jen na tomto Macu
/// (na webu `localStorage`).
@MainActor
@Observable
public final class Advisor {
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private var cache: (revision: Int, bucket: Int, value: Advice)?
    /// Den (`YYYY-MM-DD`), pro který je ranní výzva skrytá.
    private var morningDismissedDay: String?

    static let morningKey = "st.dismiss.morning"
    static let bucketMs = 5 * StudyClock.minute

    public init(store: AppStore) {
        self.store = store
        morningDismissedDay = store.defaults.string(forKey: Self.morningKey)
    }

    /// Doporučení a hláška nad nimi (pozdní hodina, splněný cíl, slabší denní doba).
    public struct Advice: Equatable, Sendable {
        public let recommendations: [Recommendation]
        public let note: String?
    }

    public func advice(now: Int) -> Advice {
        let revision = store.revision
        let bucket = now / Self.bucketMs
        if let cache, cache.revision == revision, cache.bucket == bucket { return cache.value }
        let doc = store.document
        let value = Advice(
            recommendations: Recommender(document: doc, now: now, clock: store.clock).recommend(),
            note: Recommender.contextNote(doc, now: now, clock: store.clock)
        )
        cache = (revision, bucket, value)
        return value
    }

    /// Doporučení seřazená od nejlepšího.
    public func recommendations(now: Int) -> [Recommendation] {
        advice(now: now).recommendations
    }

    /// Ranní výzva na Přehledu: dopoledne (5–13 h), dokud na dnešek není nic v plánu, a jen když jsou předměty.
    public func showsMorningPrompt(now: Int) -> Bool {
        let doc = store.document
        let clock = store.clock
        let hour = clock.hour(now)
        guard doc.settings.morningPrompt, hour >= 5, hour < 13, morningDismissedDay != clock.dayKey(now),
              !doc.alive(Subject.self).isEmpty else { return false }
        let today = clock.startOfDay(now), tomorrow = clock.addDays(today, 1)
        return !doc.alive(PlanBlock.self).contains { $0.start >= today && $0.start < tomorrow }
    }

    public func dismissMorningPrompt(now: Int) {
        let day = store.clock.dayKey(now)
        morningDismissedDay = day
        store.defaults.set(day, forKey: Self.morningKey)
    }
}
