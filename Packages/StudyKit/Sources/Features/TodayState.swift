import Core
import Engine
import Foundation

/// Stránka Dnes jako seznam: bloky plánu a neplánovaná sezení po částech dne (dopoledne, odpoledne,
/// večer), obsazený čas z rozvrhu a kalendářů a volné chvíle s návrhem bloku. Čistá funkce dat
/// a okamžiku – pohled jen kreslí.
public struct TodayState: Sendable {
    public enum Part: Int, CaseIterable, Sendable {
        case morning, afternoon, evening

        public var title: String {
            switch self {
            case .morning: "Dopoledne"
            case .afternoon: "Odpoledne"
            case .evening: "Večer"
            }
        }

        /// Dopoledne do 12:00, odpoledne do 18:00, pak večer.
        static func of(_ t: Int, clock: StudyClock) -> Part {
            let m = clock.minutesOfDay(t)
            return m < 12 * 60 ? .morning : m < 18 * 60 ? .afternoon : .evening
        }
    }

    /// Blok plánu nebo odučené sezení.
    public struct Item: Identifiable, Hashable, Sendable {
        public enum Status: Hashable, Sendable { case done, open, missed, running }

        public let id: String
        /// Blok plánu (`nil` = sezení mimo plán nebo blok bez plánu, který právě běží).
        public let planBlockId: String?
        public let start: Int
        public let end: Int
        public let subject: SubjectInfo
        /// Název bloku nebo téma sezení (může být prázdný – pak se ukáže předmět).
        public let title: String
        /// Téma pro časovač.
        public let topic: String
        public let status: Status
        /// „zápočet za 4 dny“ – blízká zkouška z předmětu bloku.
        public let examHint: String?

        public var durationMin: Int { max(0, (end - start) / StudyClock.minute) }
    }

    /// Obsazený čas: výuka z rozvrhu nebo událost z jiného kalendáře.
    public struct Busy: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let start: Int
        public let end: Int

        public init(id: String, title: String, start: Int, end: Int) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// Návrh bloku do volné chvíle (z doporučení „Co teď?“).
    public struct Suggestion: Hashable, Sendable {
        public let subject: SubjectInfo
        public let title: String
        public let topic: String
        public let modeId: String
        public let start: Int
        public let minutes: Int
        public let reasons: [String]
    }

    /// Volná chvíle od teď do konce plánovaného dne.
    public struct Gap: Identifiable, Hashable, Sendable {
        public let start: Int
        public let end: Int
        public let suggestion: Suggestion?
        public var id: Int { start }
    }

    public enum Entry: Identifiable, Hashable, Sendable {
        case item(Item)
        case busy(Busy)
        case gap(Gap)

        public var id: String {
            switch self {
            case .item(let i): "item.\(i.id)"
            case .busy(let b): "busy.\(b.id)"
            case .gap(let g): "gap.\(g.start)"
            }
        }

        var start: Int {
            switch self {
            case .item(let i): i.start
            case .busy(let b): b.start
            case .gap(let g): g.start
            }
        }
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public let part: Part
        public let entries: [Entry]
        /// „2 bloky · 1 h 25 min“
        public let meta: String?
        public var id: Int { part.rawValue }
    }

    /// Běžící (nebo pozastavený) blok učení z časovače.
    public struct Running: Sendable {
        public let planBlockId: String?
        public let subjectId: String
        public let topic: String
        public let start: Int
        /// Kdy blok podle časovače skončí (u počítání nahoru odhad).
        public let end: Int

        public init(planBlockId: String?, subjectId: String, topic: String, start: Int, end: Int) {
            self.planBlockId = planBlockId
            self.subjectId = subjectId
            self.topic = topic
            self.start = start
            self.end = end
        }
    }

    public let sections: [Section]
    public let tomorrow: [Item]
    /// Do denního cíle zbývá (0 = splněno nebo bez cíle).
    public let remainingSec: Int
    public let goalSec: Int

    /// Volná chvíle se ukáže od této délky (vejde se do ní aspoň krátký blok).
    static let minimumGapMinutes = 30
    /// Návrhy jen do prvních tří volných chvil – víc by seznam zahltilo.
    static let maxSuggestions = 3

    public init(document doc: AppDocument, now: Int, clock: StudyClock, external: [Busy] = [], running: Running? = nil,
                recommendations: [Recommendation] = []) {
        let subjects = SubjectLookup(doc)
        let today = clock.startOfDay(now)
        let tomorrowStart = clock.addDays(today, 1)
        let examHints = Self.examHints(doc, today: today, clock: clock)

        func item(_ b: PlanBlock, status: Item.Status) -> Item {
            Item(id: b.id, planBlockId: b.id, start: b.start, end: b.start + b.durationMin * StudyClock.minute, subject: subjects[b.subjectId],
                 title: b.title, topic: blockTopics(b.title).first ?? "", status: status, examHint: examHints[b.subjectId])
        }

        // Bloky plánu dneška.
        let blocks = doc.alive(PlanBlock.self).filter { $0.start >= today && $0.start < tomorrowStart }
        var items: [Item] = blocks.map { b in
            let status: Item.Status = b.done ? .done
                : running?.planBlockId == b.id ? .running
                : b.start + b.durationMin * StudyClock.minute <= now ? .missed : .open
            return item(b, status: status)
        }
        // Sezení mimo plán (hotový blok stejného předmětu ve stejnou dobu už je v seznamu).
        let doneBlocks = blocks.filter(\.done)
        for s in doc.alive(Session.self) where s.start >= today && s.start < tomorrowStart {
            let covered = doneBlocks.contains { b in
                b.subjectId == s.subjectId && s.start < b.start + b.durationMin * StudyClock.minute && s.end > b.start
            }
            guard !covered else { continue }
            items.append(Item(id: "session.\(s.id)", planBlockId: nil, start: s.start, end: s.end, subject: subjects[s.subjectId],
                              title: s.topic, topic: s.topic, status: .done, examHint: nil))
        }
        // Blok, který běží bez plánu.
        if let running, running.planBlockId.map({ id in !blocks.contains { $0.id == id } }) ?? true {
            items.append(Item(id: "timer", planBlockId: nil, start: running.start, end: running.end, subject: subjects[running.subjectId],
                              title: running.topic, topic: running.topic, status: .running, examHint: examHints[running.subjectId]))
        }

        // Obsazený čas: výuka z rozvrhu a události z jiných kalendářů.
        let lectures = Timetables.lectures(doc, from: today, to: tomorrowStart)
            .map { Busy(id: "lecture.\($0.event.key)", title: $0.event.title.isEmpty ? "Výuka" : $0.event.title, start: $0.event.start, end: $0.event.end) }
        let busy = (lectures + external.filter { $0.end > today && $0.start < tomorrowStart })

        // Volné chvíle od teď do konce plánovaného dne, s návrhy z doporučení.
        let settings = doc.settings
        let bounds = DayPlan.dayBounds(settings, now: now, clock: clock)
        var occupied = DayPlan.busyIntervals(doc, day: today, clock: clock, external: external.map { BusyInterval(start: $0.start, end: $0.end) })
        if let running { occupied.append(BusyInterval(start: running.start, end: max(running.end, now))) }
        let free = bounds.from < bounds.to
            ? DayPlan.freeTime(occupied, from: bounds.from, to: bounds.to, minutes: Self.minimumGapMinutes) : []
        var candidates = recommendations.filter { $0.subjectId != nil && $0.planBlockId == nil && $0.activity != .anki }
        let gaps: [Gap] = free.enumerated().map { index, slot in
            guard index < Self.maxSuggestions, !candidates.isEmpty else { return Gap(start: slot.start, end: slot.end, suggestion: nil) }
            let rec = candidates.removeFirst()
            let start = Self.roundUp(slot.start, toMinutes: 5)
            let fits = (slot.end - start) / StudyClock.minute / 5 * 5
            let suggestion = Suggestion(subject: subjects[rec.subjectId ?? ""], title: rec.title, topic: rec.topic, modeId: rec.modeId,
                                        start: start, minutes: min(rec.minutes, fits), reasons: rec.reasons)
            return Gap(start: slot.start, end: slot.end, suggestion: suggestion)
        }

        let entries: [Entry] = (items.map(Entry.item) + busy.map(Entry.busy) + gaps.map(Entry.gap)).sorted { $0.start < $1.start }
        sections = Part.allCases.compactMap { part in
            let list = entries.filter { Part.of($0.start, clock: clock) == part }
            guard !list.isEmpty else { return nil }
            let study = list.compactMap { if case .item(let i) = $0 { i } else { nil } }
            let meta = study.isEmpty ? nil
                : "\(study.count) \(Format.plural(study.count, "blok", "bloky", "bloků")) · \(Format.duration(study.reduce(0) { $0 + $1.durationMin } * 60))"
            return Section(part: part, entries: list, meta: meta)
        }

        tomorrow = doc.alive(PlanBlock.self)
            .filter { $0.start >= tomorrowStart && $0.start < clock.addDays(tomorrowStart, 1) }
            .sorted { $0.start < $1.start }
            .map { item($0, status: .open) }

        goalSec = settings.dailyGoalMin * 60
        let studied = Stats.totalSec(Stats.inRange(doc.alive(Session.self), from: today, to: now + 1))
        remainingSec = max(0, goalSec - studied)
    }

    /// Nejbližší zkouška do 14 dní pro každý předmět: „zápočet za 4 dny“, „zkouška zítra“.
    static func examHints(_ doc: AppDocument, today: Int, clock: StudyClock) -> [String: String] {
        var out: [String: (days: Int, text: String)] = [:]
        for e in doc.alive(Exam.self) {
            guard let day = clock.parseDayKey(e.date), day >= today else { continue }
            let days = Int((Double(day - today) / Double(StudyClock.day)).rounded())
            guard days <= 14, out[e.subjectId].map({ days < $0.days }) ?? true else { continue }
            let when = days == 0 ? "dnes" : days == 1 ? "zítra" : "za \(days) \(Format.plural(days, "den", "dny", "dní"))"
            out[e.subjectId] = (days, "\(kind(of: e.name)) \(when)")
        }
        return out.mapValues(\.text)
    }

    /// Druh zkoušky z názvu („Zápočet z anatomie“ → zápočet); jinak obecně „zkouška“.
    static func kind(of name: String) -> String {
        let first = name.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let known = ["zkouška", "zápočet", "test", "kolokvium", "písemka", "státnice", "atestace", "zkoušení"]
        return known.contains(first) ? first : "zkouška"
    }

    static func roundUp(_ t: Int, toMinutes m: Int) -> Int {
        let step = m * StudyClock.minute
        return t % step == 0 ? t : (t / step + 1) * step
    }
}
