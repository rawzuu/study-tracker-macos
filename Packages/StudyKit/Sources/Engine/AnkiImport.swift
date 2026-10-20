import Core
import Foundation

/// Čas z Anki v datech (`runAnkiSync` v `useAnkiSync.ts` na webu v2.6.7): dnešní stav balíčků jako záznam
/// `snapshot` a opakování jako sezení (blok = opakování bez pauzy delší než 10 min, předmět podle balíčku).
/// Sezení mají stálá id (`anki-<balíček>-<začátek>`), takže web i Mac zapíšou stejné záznamy. Smazané
/// sezení z Anki se nevrací; když Anki nevrátí žádnou historii (jiný profil), nic se nemaže.
public enum AnkiImport {
    /// Předmět pro balíčky bez přiřazení (`ANKI_SUBJECT_ID`).
    public static let subjectId = "anki"
    /// Pauza mezi odpověďmi, po které začíná nový blok.
    public static let blockGap = 10 * StudyClock.minute

    /// Jedno zodpovězení karty (balíček nejvyšší úrovně).
    public struct Review: Sendable, Hashable {
        public let deck: String
        public let time: Int
        public let durationMs: Int

        public init(deck: String, time: Int, durationMs: Int) {
            self.deck = deck
            self.time = time
            self.durationMs = durationMs
        }
    }

    /// Co se z Anki načetlo.
    public struct Fetch: Sendable {
        public let decks: [AnkiDeckStat]
        public let reviewedToday: Int
        public let reviews: [Review]
        /// `false` = historie se nestahovala (od minula žádné nové opakování).
        public let reviewsFetched: Bool

        public init(decks: [AnkiDeckStat], reviewedToday: Int, reviews: [Review], reviewsFetched: Bool) {
            self.decks = decks
            self.reviewedToday = reviewedToday
            self.reviews = reviews
            self.reviewsFetched = reviewsFetched
        }
    }

    /// Souvislý blok opakování v jednom balíčku (`clusterReviews`).
    public struct Block: Sendable, Hashable {
        public let deck: String
        public let start: Int
        public var end: Int
        public var durationMs: Int
        public var count: Int
    }

    /// Změny dat po načtení – prázdné = nic se nezapisuje (ani na GitHub).
    public struct Changes: Sendable {
        public var snapshot: AnkiSnapshot?
        public var subject: Subject?
        public var sessions: [Session] = []
        public var remove: [String] = []

        public var isEmpty: Bool { snapshot == nil && subject == nil && sessions.isEmpty && remove.isEmpty }
    }

    /// Začátek okna, které Mac spravuje: při prvním propojení nebo přepočtu `importDays` dní, jinak dva dny.
    public static func since(_ doc: AppDocument, fullHistory: Bool, now: Int, clock: StudyClock) -> Int {
        let hasAnkiSessions = doc.alive(Session.self).contains { $0.mode == "anki" }
        let days = fullHistory || !hasAnkiSessions ? doc.settings.anki.importDays : 2
        return clock.addDays(clock.startOfDay(now), -(days - 1))
    }

    /// Od kdy se ptát Anki: o den dřív než okno, aby se blok přes půlnoc na hranici okna nerozpůlil.
    public static func fetchFrom(since: Int, clock: StudyClock) -> Int { clock.addDays(since, -1) }

    /// Bloky opakování zvlášť pro každý balíček (v pořadí, v jakém se balíčky poprvé objeví).
    public static func blocks(_ reviews: [Review], gap: Int = blockGap) -> [Block] {
        var order: [String] = []
        var byDeck: [String: [Review]] = [:]
        for r in reviews {
            if byDeck[r.deck] == nil { order.append(r.deck) }
            byDeck[r.deck, default: []].append(r)
        }
        var out: [Block] = []
        for deck in order {
            var current: Block?
            for r in byDeck[deck]! {
                if var c = current, r.time - c.end <= gap {
                    c.end = r.time
                    c.durationMs += r.durationMs
                    c.count += 1
                    current = c
                } else {
                    if let current { out.append(current) }
                    current = Block(deck: deck, start: r.time - r.durationMs, end: r.time, durationMs: r.durationMs, count: 1)
                }
            }
            if let current { out.append(current) }
        }
        return out
    }

    /// `\p{L}` a `\p{N}` v regulárním výrazu webu.
    private static let letterOrNumber: Set<Unicode.GeneralCategory> = [
        .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
    ]

    /// `anki-<balíček>-<začátek>`: v názvu balíčku se každý úsek mimo písmena a číslice nahradí `_`.
    public static func sessionId(deck: String, start: Int) -> String {
        var name = ""
        var inGap = false
        for ch in deck.unicodeScalars {
            if Self.letterOrNumber.contains(ch.properties.generalCategory) {
                name.unicodeScalars.append(ch)
                inGap = false
            } else if !inGap {
                name += "_"
                inGap = true
            }
        }
        return "anki-\(name)-\(start)"
    }

    /// Co zapsat po načtení z Anki (`run` v `useAnkiSync.ts`).
    public static func changes(_ doc: AppDocument, fetch: Fetch, since: Int, now: Int, clock: StudyClock) -> Changes {
        var out = Changes()
        let settings = doc.settings.anki
        let today = clock.startOfDay(now)

        // Stav balíčků – jen když se změnila čísla (minuty dneška zaokrouhleně)
        let prev = doc.records(AnkiSnapshot.self).first { $0.id == "snapshot" }
        let msToday = fetch.reviewsFetched ? fetch.reviews.filter { $0.time >= today }.reduce(0) { $0 + $1.durationMs } : (prev?.msToday ?? 0)
        let decks: [JSONValue] = fetch.decks.map { .object($0.raw) }
        if prev.map({ !sameSignature($0, decks: decks, reviewedToday: fetch.reviewedToday, msToday: msToday) }) ?? true {
            out.snapshot = AnkiSnapshot(raw: [
                "id": "snapshot", "at": .number(Double(now)), "decks": .array(decks),
                "reviewedToday": .number(Double(fetch.reviewedToday)), "msToday": .number(Double(msToday)),
            ])
        }

        guard settings.countTime, fetch.reviewsFetched else { return out }
        let mapping = settings.deckSubjects
        let unmapped = fetch.reviews.contains { (mapping[$0.deck] ?? "").isEmpty }
        if unmapped && !doc.alive(Subject.self).contains(where: { $0.id == subjectId }) {
            out.subject = Subject(raw: ["id": .string(subjectId), "name": "Anki", "color": "#9ca3af", "weeklyGoalMin": 0, "archived": false])
        }

        var wanted: [String: Session] = [:]
        var order: [String] = []
        // Okno spravuje bloky, které do něj aspoň zasahují (i ty začaté před půlnocí).
        for b in blocks(fetch.reviews) where b.durationMs >= 30_000 && b.end >= since {
            let id = sessionId(deck: b.deck, start: b.start)
            let subject = mapping[b.deck].flatMap { $0.isEmpty ? nil : $0 } ?? subjectId
            if wanted[id] == nil { order.append(id) }
            wanted[id] = Session(raw: [
                "id": .string(id), "subjectId": .string(subject), "topic": .string(b.deck), "start": .number(Double(b.start)),
                "end": .number(Double(max(b.end, b.start + b.durationMs))), "durationSec": .number(JS.round(Double(b.durationMs) / 1000)),
                "mode": "anki", "interruptions": 0, "note": .string("\(b.count) karet"),
            ])
        }
        let existing = doc.records(Session.self).filter { $0.mode == "anki" && ($0.start >= since || $0.end >= since) }
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        out.sessions = order.compactMap { id in
            let w = wanted[id]!
            guard let e = byId[id] else { return w }
            if e.isDeleted { return nil }
            return e.end != w.end || e.durationSec != w.durationSec || e.subjectId != w.subjectId ? w : nil
        }
        // Bloky, které po přepočtu v okně už neexistují, se smažou – jen když Anki nějakou historii vrátila.
        if !fetch.reviews.isEmpty {
            out.remove = existing.filter { !$0.isDeleted && wanted[$0.id] == nil }.map(\.id)
        }
        return out
    }

    /// `JSON.stringify([decks, reviewedToday, Math.round(msToday / 60000)])` beze změny.
    private static func sameSignature(_ prev: AnkiSnapshot, decks: [JSONValue], reviewedToday: Int, msToday: Int) -> Bool {
        prev.raw["decks"] == .array(decks) && prev.reviewedToday == reviewedToday
            && JS.round(Double(prev.msToday) / 60_000) == JS.round(Double(msToday) / 60_000)
    }

    /// Dnešní stav z Anki pro přehled: `nil` = ještě nikdy nenačteno.
    public struct Today: Sendable, Hashable {
        public let at: Int
        /// Stav je z dneška (jinak jen poslední známý).
        public let fresh: Bool
        public let due: Int
        public let new: Int
        public let learn: Int
        public let review: Int
        public let decks: [AnkiDeckStat]
        public let reviewedToday: Int
        public let msToday: Int
    }

    public static func today(_ doc: AppDocument, now: Int, clock: StudyClock) -> Today? {
        guard let snap = doc.records(AnkiSnapshot.self).first(where: { $0.id == "snapshot" && !$0.isDeleted }) else { return nil }
        let n = snap.decks.reduce(0) { $0 + $1.newCount }, l = snap.decks.reduce(0) { $0 + $1.learnCount }
        let r = snap.decks.reduce(0) { $0 + $1.reviewCount }
        return Today(at: snap.at, fresh: clock.startOfDay(snap.at) == clock.startOfDay(now), due: n + l + r, new: n, learn: l, review: r,
                     decks: snap.decks, reviewedToday: snap.reviewedToday, msToday: snap.msToday)
    }
}

extension AnkiDeckStat {
    /// Balíček v pořadí klíčů jako na webu (`{ name, newCount, learnCount, reviewCount, total }`).
    public init(name: String, newCount: Int, learnCount: Int, reviewCount: Int, total: Int) {
        self.init(raw: [
            "name": .string(name), "newCount": .number(Double(newCount)), "learnCount": .number(Double(learnCount)),
            "reviewCount": .number(Double(reviewCount)), "total": .number(Double(total)),
        ])
    }
}
