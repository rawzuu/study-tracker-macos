import Core
import Foundation

/// Navržený blok ranního plánu.
public struct DayPlanItem: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public var subjectId: String
    public var title: String
    public var minutes: Int
    /// Začátek; 0 = do dnešního dne se nevejde.
    public var start: Int
    public var activity: Activity
    public var reasons: [String]
    /// Zaškrtnuto – uloží se do kalendáře.
    public var include: Bool
    /// Existující nedokončený blok, který se jen přesune.
    public var carry: PlanBlock?

    public var isPlaced: Bool { start != 0 }

    /// Mac: název bloku bez „Pokračovat: téma“ – blok je o předmětu, ne o tom, kde jsi skončil.
    public var displayTitle: String { activity == .continue ? "" : title }
}

/// Obsazený úsek dne (výuka, plán, odučený čas).
public struct BusyInterval: Sendable, Hashable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// Ranní plánování (`src/lib/dayplan.ts` na webu): navrhne bloky na zbytek dne.
///
/// 1. Nabídne přesunutí nedokončených bloků z posledních dvou dnů.
/// 2. Opakovaně volá „Co teď?“ a simuluje, že vybraný blok už je v plánu (sníží zaostávání za cílem,
///    přidá penalizaci za stejný předmět) – výsledkem je prokládaný plán podle priorit, dokud se nenaplní
///    denní cíl.
/// 3. Rozmístí bloky do volných míst: náročnou látku do tvé nejsilnější doby podle soustředění, zbytek
///    co nejdřív. Stejný předmět nikdy dvakrát za sebou (když je z čeho vybírat), pauza podle délky bloku.
///
/// Rozvrh je obsazený čas. Opakování po přednášce Mac nenavrhuje (opakování na Macu není).
public enum DayPlan {
    static let gap = 10 * StudyClock.minute

    /// Pauza po bloku podle jeho délky (25 → 5 min, 50 → 10 min, 90 → 20 min).
    public static func breakAfter(_ minutes: Int) -> Int {
        min(20, max(5, Int(JS.round(Double(minutes) / 25)) * 5))
    }

    /// Nastavené rozmezí plánovaného dne (bez ohledu na aktuální čas).
    public static func dayRange(_ settings: Settings, day: Int, clock: StudyClock) -> (start: Int, end: Int) {
        (hm(day, settings.planDayStart, clock: clock), hm(day, settings.planDayEnd, clock: clock))
    }

    /// Plánovaný den a jeho zbytek: od teď (zaokrouhleno nahoru na 15 min), nejdřív od začátku rozmezí.
    public static func dayBounds(_ settings: Settings, now: Int, clock: StudyClock) -> (day: Int, from: Int, to: Int) {
        let day = clock.startOfDay(now)
        let q = 15 * StudyClock.minute
        let roundUp = now % q == 0 ? now : (now / q + 1) * q
        let range = dayRange(settings, day: day, clock: clock)
        return (day, max(roundUp, range.start), range.end)
    }

    /// `HH:MM` v daném dni (`hm` na webu: chybějící nebo neplatná část = 0, „24:00“ = půlnoc dalšího dne).
    public static func hm(_ day: Int, _ value: String, clock: StudyClock) -> Int {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map { ICal.jsNumber(String($0)) }
        let h = parts.first.flatMap { $0 } ?? 0, m = parts.count > 1 ? parts[1] ?? 0 : 0
        let total = (h.isFinite ? h : 0) * 60 + (m.isFinite ? m : 0)
        return clock.atMinutes(day, Int(total))
    }

    /// Obsazené úseky dne (výuka, plán, odučené a `external` – události z Apple Kalendáře), seřazené podle začátku.
    public static func busyIntervals(_ doc: AppDocument, day: Int, excluding exclude: Set<String> = [], clock: StudyClock,
                                     external: [BusyInterval] = []) -> [BusyInterval] {
        busyIntervals(doc, sessions: SessionFacts.alive(in: doc), day: day, excluding: exclude, external: external, clock: clock)
    }

    static func busyIntervals(_ doc: AppDocument, sessions: [SessionFacts], day: Int, excluding exclude: Set<String>,
                              external: [BusyInterval] = [], clock: StudyClock) -> [BusyInterval] {
        let next = clock.addDays(day, 1)
        var out = Timetables.lectures(doc, from: day, to: next).map { BusyInterval(start: $0.event.start, end: $0.event.end) }
        // Mac: události z ostatních kalendářů, které do dne zasahují (web je nezná).
        out += external.filter { $0.end > day && $0.start < next }
        for b in doc.alive(PlanBlock.self) where !exclude.contains(b.id) && b.start >= day && b.start < next {
            out.append(BusyInterval(start: b.start, end: b.start + b.durationMin * StudyClock.minute))
        }
        for s in sessions where s.start >= day && s.start < next {
            out.append(BusyInterval(start: s.start, end: s.end))
        }
        return JS.sort(out) { Recommender.order(Double($0.start - $1.start)) }
    }

    /// Nejbližší volné místo dané délky od `from` (s pauzou 10 min kolem obsazených úseků).
    public static func findSlot(_ busy: [BusyInterval], from: Int, to: Int, minutes: Int) -> Int? {
        var t = from
        let len = minutes * StudyClock.minute
        for b in busy {
            if b.end + gap <= t { continue }
            if b.start - gap >= t + len { break }
            t = max(t, b.end + gap)
        }
        return t + len <= to ? t : nil
    }

    /// Volná místa mezi obsazenými úseky (s pauzou 10 min kolem nich jako u `findSlot`), nejméně
    /// `minutes` dlouhá, v rozmezí `from`–`to`.
    public static func freeTime(_ busy: [BusyInterval], from: Int, to: Int, minutes: Int) -> [BusyInterval] {
        let len = minutes * StudyClock.minute
        var out: [BusyInterval] = []
        var t = from
        for b in busy.sorted(by: { $0.start < $1.start }) {
            let end = min(b.start - gap, to)
            if end - t >= len { out.append(BusyInterval(start: t, end: end)) }
            t = max(t, b.end + gap)
            if t >= to { return out }
        }
        if to - t >= len { out.append(BusyInterval(start: t, end: to)) }
        return out
    }

    /// Návrh bloků na zbytek dne. `extra` = kolikrát uživatel přidal „Další blok“ (+25 min k cíli),
    /// `external` = obsazený čas z Apple Kalendáře.
    public static func propose(_ doc: AppDocument, now: Int, extra: Int = 0, clock: StudyClock, external: [BusyInterval] = []) -> [DayPlanItem] {
        // sezení se z dat čtou jednou pro doporučení, cíl i rozmístění
        propose(doc, sessions: SessionFacts.alive(in: doc), ahead: [], now: now, extra: extra, carry: true, clock: clock, external: external)
    }

    /// Plánovaný den s návrhem (Mac: plán na víc dní dopředu).
    public struct PlannedDay: Sendable, Hashable, Identifiable {
        public let day: Int
        /// Okamžik, od kterého se den plánuje: dnes teď, jindy začátek rozmezí dne.
        public let now: Int
        public var items: [DayPlanItem]
        public var id: Int { day }
    }

    /// Mac: návrh na víc dní dopředu (`days` = začátky dnů od dneška dál). Každý den se plánuje jako jeho
    /// ranní plán – od začátku rozmezí dne, s jeho výukou a událostmi z Apple Kalendáře a se vzdáleností
    /// zkoušek od toho dne. Co je ve dnech předtím navržené nebo už naplánované, se bere jako odučené:
    /// týdenní cíl se plní a předmět, který byl dlouho bez učení, se nenavrhuje každý den znovu.
    /// Dnešek je přesně ranní plán (i s přesunem nedokončených bloků), další dny bez přesunu.
    public static func propose(_ doc: AppDocument, days: [Int], now: Int, extra: Int = 0, clock: StudyClock,
                               external: [BusyInterval] = []) -> [PlannedDay] {
        let today = clock.startOfDay(now)
        let sessions = SessionFacts.alive(in: doc)
        let pending = doc.alive(PlanBlock.self).filter { !$0.done && $0.start >= now }
        var proposed: [SessionFacts] = []
        var out: [PlannedDay] = []
        for day in days.sorted() where day >= today {
            let at = day == today ? now : dayRange(doc.settings, day: day, clock: clock).start
            let ahead = pending.filter { $0.start < day }.map { SessionFacts(planned: $0.subjectId, start: $0.start, minutes: $0.durationMin) }
            let items = propose(doc, sessions: sessions, ahead: ahead + proposed, now: at, extra: extra, carry: day == today,
                                clock: clock, external: external)
            proposed += items.filter { $0.include && $0.isPlaced }.map { SessionFacts(planned: $0.subjectId, start: $0.start, minutes: $0.minutes) }
            out.append(PlannedDay(day: day, now: at, items: items))
        }
        return out
    }

    /// `ahead` = bloky z dřívějších dnů plánu, které doporučení počítá jako odučené (ne cíl dne ani rozmístění).
    static func propose(_ doc: AppDocument, sessions: [SessionFacts], ahead: [SessionFacts], now: Int, extra: Int, carry: Bool,
                        clock: StudyClock, external: [BusyInterval]) -> [DayPlanItem] {
        let settings = doc.settings
        let day = clock.startOfDay(now)
        let next = clock.addDays(day, 1)
        let blocks = doc.alive(PlanBlock.self)
        let studied = sessions.filter { $0.start >= day }.reduce(0.0) { $0 + Double($1.durationSec) / 60 }
        let plannedLeft = blocks
            .filter { !$0.done && $0.start >= day && $0.start < next && $0.start + $0.durationMin * StudyClock.minute > now }
            .reduce(0) { $0 + $1.durationMin }
        var target = max(0, Double(settings.dailyGoalMin) - studied - Double(plannedLeft)) + Double(extra * 25)

        var items: [DayPlanItem] = []
        // 1) nedokončené bloky z posledních 2 dnů
        let yesterday = clock.addDays(day, -1)
        for b in blocks where carry && !b.done && b.start < day && b.start >= clock.addDays(day, -2) {
            items.append(DayPlanItem(
                key: "carry-\(b.id)", subjectId: b.subjectId, title: b.title.isEmpty ? "Nedokončený blok" : b.title, minutes: b.durationMin,
                start: 0, activity: .carry, reasons: ["nedokončeno " + (b.start >= yesterday ? "včera" : "předevčírem")], include: true, carry: b
            ))
            target -= Double(b.durationMin)
        }

        // 2) doporučení se simulací – plní se do cíle (i když už žádný předmět nemá kladné skóre)
        let recommender = Recommender(document: doc, sessions: ahead.isEmpty ? sessions : sessions + ahead, now: now, clock: clock)
        var sim = Recommender.Simulation()
        for it in items { sim.extraMinutes[it.subjectId, default: 0] += Double(it.minutes) }
        var round = 0
        while target > 10 && round < 10 {
            round += 1
            let pool = recommender.recommend(sim).filter { $0.subjectId != nil }
            guard let first = pool.first else { break }
            // Prokládání: stejný předmět nikdy dvakrát po sobě, pokud je jiný aktivní předmět (i s nižší prioritou)
            let r = first.subjectId != sim.lastSubject ? first : pool.first { $0.subjectId != sim.lastSubject } ?? first
            let subjectId = r.subjectId!
            let minutes = min(r.minutes, Int(max(25, JS.round(target / 5) * 5)))
            items.append(DayPlanItem(
                key: "rec-\(round)-\(r.key)", subjectId: subjectId, title: r.title, minutes: minutes, start: 0,
                activity: r.activity, reasons: Array(r.reasons.prefix(2)), include: true, carry: nil
            ))
            sim.extraMinutes[subjectId, default: 0] += Double(minutes)
            // čas běží – starší bloky váží méně
            for k in sim.recentMinutes.keys { sim.recentMinutes[k]! *= 0.5 }
            sim.recentMinutes[subjectId, default: 0] += Double(minutes)
            sim.lastSubject = subjectId
            target -= Double(minutes)
        }
        return place(doc, items: items, sessions: sessions, now: now, external: external, clock: clock)
    }

    /// Rozmístí položky do volných míst dne:
    ///  1. náročné bloky (zkouška, látka) do nejsilnější doby podle soustředění, pokud je ještě před tebou,
    ///  2. zbytek v pořadí návrhu do nejbližších volných míst – dopoledne tak nezůstane prázdné.
    /// Stejný předmět nikdy těsně za sebou (když jsou v plánu i jiné) a pauza po bloku podle jeho délky.
    /// Co se nevejde, má `start` 0 a není zaškrtnuté. Seřazeno podle začátku.
    public static func place(_ doc: AppDocument, items: [DayPlanItem], now: Int, clock: StudyClock, external: [BusyInterval] = []) -> [DayPlanItem] {
        place(doc, items: items, sessions: SessionFacts.alive(in: doc), now: now, external: external, clock: clock)
    }

    static func place(_ doc: AppDocument, items: [DayPlanItem], sessions: [SessionFacts], now: Int, external: [BusyInterval] = [],
                      clock: StudyClock) -> [DayPlanItem] {
        let (day, from, to) = dayBounds(doc.settings, now: now, clock: clock)
        var busy = busyIntervals(doc, sessions: sessions, day: day, excluding: Set(items.compactMap { $0.carry?.id }), external: external, clock: clock)
        let recent = sessions.filter { $0.start > now - 60 * StudyClock.day && $0.mode != "anki" }
        let peakFrom = Stats.focusWindow(recent, clock: clock).map { clock.atMinutes(day, $0.from * 60) }
        let varied = Set(items.map(\.subjectId)).count > 1
        let minute = StudyClock.minute

        var placed: [(item: DayPlanItem, start: Int)] = []
        var startOf: [String: Int] = [:]

        /// Stejný předmět nesmí být těsně za sebou (méně než hodinu mezi bloky).
        func neighboursOk(_ it: DayPlanItem, _ start: Int) -> Bool {
            guard varied else { return true }
            let end = start + it.minutes * minute
            let prev = placed.filter { $0.start < start }.max { $0.start < $1.start }
            let next = placed.filter { $0.start > start }.min { $0.start < $1.start }
            let prevOk = prev.map { $0.item.subjectId != it.subjectId || start - ($0.start + $0.item.minutes * minute) >= StudyClock.hour } ?? true
            let nextOk = next.map { $0.item.subjectId != it.subjectId || $0.start - end >= StudyClock.hour } ?? true
            return prevOk && nextOk
        }
        func commit(_ it: DayPlanItem, _ start: Int) {
            // pauza po bloku podle délky: findSlot počítá s pauzou 10 min, úsek se proto prodlouží o rozdíl
            let interval = BusyInterval(start: start, end: start + it.minutes * minute + breakAfter(it.minutes) * minute - gap)
            busy.insert(interval, at: busy.firstIndex { $0.start > start } ?? busy.endIndex)
            placed.append((it, start))
            startOf[it.key] = start
        }
        /// Nejdřívější volné místo v [lo, hi], které nekoliduje se sousedy.
        func slot(_ it: DayPlanItem, _ lo: Int, _ hi: Int, strict: Bool = true) -> Int? {
            var t = lo
            for _ in 0..<80 {
                guard let s = findSlot(busy, from: t, to: hi, minutes: it.minutes) else { return nil }
                if !strict || neighboursOk(it, s) { return s }
                t = s + 15 * minute
            }
            return nil
        }

        // 1) náročné bloky do nejsilnější doby
        if let peakFrom, peakFrom + 2 * StudyClock.hour > from {
            for it in items where it.activity == .exam || it.activity == .continue {
                if let s = slot(it, max(from, peakFrom), min(to, peakFrom + 2 * StudyClock.hour + it.minutes * minute)) { commit(it, s) }
            }
        }
        // 2) zbytek: opakovaně vyber položku (v pořadí návrhu), která se vejde nejdřív
        var rest = items.filter { startOf[$0.key] == nil }
        while !rest.isEmpty {
            var pick: (index: Int, start: Int)?
            for strict in [true, false] where pick == nil {
                // když nic nesplní střídání předmětů, vezmi aspoň první volné místo (lepší plán než žádný)
                for (i, it) in rest.enumerated() {
                    if let s = slot(it, from, to, strict: strict), pick.map({ s < $0.start }) ?? true { pick = (i, s) }
                }
            }
            guard let pick else { break }
            commit(rest[pick.index], pick.start)
            rest.remove(at: pick.index)
        }

        let out = items.map { it in
            var it = it
            if let s = startOf[it.key] {
                it.start = s
            } else {
                it.start = 0
                it.include = false
            }
            return it
        }
        return JS.sort(out) { a, b in
            let x = a.isPlaced ? Double(a.start) : .infinity, y = b.isPlaced ? Double(b.start) : .infinity
            return x.isInfinite && y.isInfinite ? 0 : Recommender.order(x - y)
        }
    }

    /// Bloky do kalendáře z vybraných položek: nedokončené se přesunou (z aktuální verze v datech),
    /// nové dostanou důvody jako poznámku a název bez „Pokračovat: téma“ (`displayTitle`).
    public static func blocks(_ items: [DayPlanItem], in doc: AppDocument) -> [PlanBlock] {
        items.filter { $0.include && $0.isPlaced }.map { i in
            if let carry = i.carry {
                var b = doc.record(PlanBlock.self, id: carry.id) ?? carry
                b.start = i.start
                b.durationMin = i.minutes
                return b
            }
            return PlanBlock(raw: [
                "id": .string(PlanBlock.newID()), "subjectId": .string(i.subjectId), "title": .string(i.displayTitle),
                "start": .number(Double(i.start)), "durationMin": .number(Double(i.minutes)), "done": false,
                "note": .string(i.reasons.joined(separator: " · ")),
            ])
        }
    }
}
