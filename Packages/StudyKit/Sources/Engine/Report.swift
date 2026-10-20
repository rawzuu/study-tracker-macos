import Core
import Foundation

/// Souhrn období pro měsíční report a týdenní reflexi (`periodStats` v `src/lib/report.ts` na webu).
/// Výsledky ověřují kontrolní data z kódu webu (Tools/parity/generate-report.ts).
public struct PeriodStats: Sendable, Hashable {
    public struct DayPart: Sendable, Hashable {
        public let label: String
        public let min: Double
        public let focus: Double?
    }

    public let from: Int
    public let to: Int
    /// Počet dní v období (u běžícího období jen do dneška).
    public let days: Int
    public let total: Int
    public let sessions: Int
    public let activeDays: Int
    /// 0–1
    public let consistency: Double
    public let avgPerActiveDay: Double
    /// Průměrná délka bloku bez Anki.
    public let avgSession: Double
    public let longestSession: Session?
    public let bestDay: (key: String, sec: Int)?
    public let longestStreak: Int
    public let focus: Double?
    /// Podíl času v blocích ≥ 45 min (bez Anki).
    public let deepShare: Double
    public let interruptionsPerHour: Double
    /// Průměrné minuty na den v týdnu (Po–Ne).
    public let weekdayAvg: [Double]
    public let hourMinutes: [Double]
    public let peakWindow: Stats.HourWindow?
    public let dayparts: [DayPart]
    public let chronotype: String
    /// Sekundy po předmětech v pořadí, v jakém se v období objevily.
    public let perSubject: [(id: String, sec: Int)]
    /// Sekundy po dnech v pořadí, v jakém se objevily.
    public let perDay: [(key: String, sec: Int)]
    /// Podíl splněných naplánovaných bloků, `nil` = nic naplánováno.
    public let planAdherence: Double?
    public let plannedSec: Int

    public func secOf(subject id: String) -> Int { perSubject.first { $0.id == id }?.sec ?? 0 }
    public func secOf(day key: String) -> Int { perDay.first { $0.key == key }?.sec ?? 0 }

    public static func == (a: PeriodStats, b: PeriodStats) -> Bool { a.from == b.from && a.to == b.to && a.total == b.total && a.sessions == b.sessions }
    public func hash(into h: inout Hasher) { h.combine(from); h.combine(to); h.combine(total) }

    static let dayPartRanges: [(label: String, from: Int, to: Int)] = [("Ráno", 5, 12), ("Odpoledne", 12, 17), ("Večer", 17, 22), ("Noc", 22, 29)]

    public init(sessions all: [Session], blocks: [PlanBlock], from: Int, to: Int, restDays: Int = 0, minMin: Int = 0, now: Int, clock: StudyClock) {
        let list = Stats.inRange(all, from: from, to: to)
        let effTo = min(to, clock.startOfDay(now) + StudyClock.day)
        self.from = from
        self.to = to
        days = max(1, Int(JS.round(Double(effTo - from) / Double(StudyClock.day))))
        total = Stats.totalSec(list)
        sessions = list.count

        var dayOrder: [String] = []
        var daySec: [String: Int] = [:]
        var subjectOrder: [String] = []
        var subjectSec: [String: Int] = [:]
        for s in list {
            let k = clock.dayKey(s.start)
            if daySec[k] == nil { dayOrder.append(k) }
            daySec[k, default: 0] += s.durationSec
            if subjectSec[s.subjectId] == nil { subjectOrder.append(s.subjectId) }
            subjectSec[s.subjectId, default: 0] += s.durationSec
        }
        perDay = dayOrder.map { ($0, daySec[$0]!) }
        perSubject = subjectOrder.map { ($0, subjectSec[$0]!) }
        activeDays = dayOrder.count
        var best: (key: String, sec: Int)?
        for d in perDay where best.map({ d.sec > $0.sec }) ?? true { best = d }
        bestDay = best

        // série v rámci období – stejná pravidla jako na přehledu (dny volna, minimum minut)
        let streakDays = Stats.streakDays(list, minMin: minMin, clock: clock)
        longestStreak = effTo > from ? Stats.longestRun(streakDays, from: from, until: effTo - 1, restDays: restDays, clock: clock) : 0

        // průměr na den v týdnu = součet / počet takových dní v období
        var wdTotals = Array(repeating: 0.0, count: 7), wdCount = Array(repeating: 0, count: 7)
        var t = from
        while t < effTo {
            let i = clock.weekdayIndex(t)
            wdCount[i] += 1
            wdTotals[i] += Double(daySec[clock.dayKey(t)] ?? 0) / 60
            t = clock.addDays(t, 1)
        }
        weekdayAvg = (0..<7).map { wdCount[$0] > 0 ? wdTotals[$0] / Double(wdCount[$0]) : 0 }

        let hours = Stats.byHour(list, clock: clock)
        hourMinutes = hours
        var peak: Stats.HourWindow?
        var top = 0.0
        for h in 0..<24 {
            let v = hours[h] + hours[(h + 1) % 24]
            if v > top {
                top = v
                peak = Stats.HourWindow(from: h)
            }
        }
        peakWindow = peak

        dayparts = Self.dayPartRanges.map { p in
            let inPart = { (h: Int) in p.to > 24 ? h >= p.from || h < p.to - 24 : h >= p.from && h < p.to }
            var min = 0.0
            for h in 0..<24 where inPart(h) { min += hours[h] }
            return DayPart(label: p.label, min: min, focus: Stats.avgFocus(list.filter { inPart(clock.hour($0.start)) }))
        }
        let totalMin = total == 0 ? 1 : Double(total) / 60
        let morning = dayparts[0].min / totalMin
        let night = (dayparts[2].min + dayparts[3].min) / totalMin
        if list.isEmpty {
            chronotype = "—"
        } else if morning >= 0.45 {
            chronotype = "Ranní ptáče"
        } else {
            chronotype = night >= 0.55 ? "Noční sova" : "Denní typ"
        }

        // Bloky z Anki jsou krátké opakování kartiček – do průměrné délky bloku a hluboké práce se nepočítají.
        let focusList = list.filter { $0.mode != "anki" }
        let focusTotal = Stats.totalSec(focusList)
        let deep = focusList.filter { $0.durationSec >= 45 * 60 }.reduce(0) { $0 + $1.durationSec }
        let interruptions = list.reduce(0) { $0 + $1.interruptions }
        consistency = Double(activeDays) / Double(days)
        avgPerActiveDay = activeDays > 0 ? Double(total) / Double(activeDays) : 0
        avgSession = focusList.isEmpty ? 0 : Double(focusTotal) / Double(focusList.count)
        var longest: Session?
        for s in focusList where longest.map({ s.durationSec > $0.durationSec }) ?? true { longest = s }
        longestSession = longest
        focus = Stats.avgFocus(list)
        deepShare = focusTotal > 0 ? Double(deep) / Double(focusTotal) : 0
        interruptionsPerHour = total > 0 ? Double(interruptions) / (Double(total) / 3600) : 0

        let past = blocks.filter { !$0.isDeleted && $0.start >= from && $0.start < min(to, now) }
        planAdherence = past.isEmpty ? nil : Double(past.filter(\.done).count) / Double(past.count)
        plannedSec = blocks.filter { !$0.isDeleted && $0.start >= from && $0.start < to }.reduce(0) { $0 + $1.durationMin * 60 }
    }
}

/// Měsíční report (`src/lib/report.ts` na webu).
public enum Report {
    public static let months = ["leden", "únor", "březen", "duben", "květen", "červen", "červenec", "srpen", "září", "říjen", "listopad", "prosinec"]
    public static let monthsIn = ["lednu", "únoru", "březnu", "dubnu", "květnu", "červnu", "červenci", "srpnu", "září", "říjnu", "listopadu", "prosinci"]
    static let weekdayIn = ["v pondělí", "v úterý", "ve středu", "ve čtvrtek", "v pátek", "v sobotu", "v neděli"]
    static let daypartWhen = ["Ráno": "ráno", "Odpoledne": "odpoledne", "Večer": "večer", "Noc": "v noci"]

    /// Začátek měsíce `month` (0–11) a začátek následujícího.
    public static func monthRange(year: Int, month: Int, clock: StudyClock) -> (from: Int, to: Int) {
        let from = clock.ms(clock.calendar.date(from: DateComponents(year: year, month: month + 1, day: 1))!)
        let to = clock.ms(clock.calendar.date(from: DateComponents(year: year, month: month + 2, day: 1))!)
        return (from, to)
    }

    /// Měsíc a rok o `delta` měsíců jinde.
    public static func shift(year: Int, month: Int, by delta: Int) -> (year: Int, month: Int) {
        let n = year * 12 + month + delta
        return (Int((Double(n) / 12).rounded(.down)), ((n % 12) + 12) % 12)
    }

    /// Výchozí měsíc reportu: v prvním týdnu měsíce uzavřený minulý měsíc, jinak aktuální.
    public static func defaultMonth(now: Int, clock: StudyClock) -> (year: Int, month: Int) {
        let c = clock.calendar.dateComponents([.year, .month, .day], from: clock.date(now))
        let current = (c.year!, c.month! - 1)
        return c.day! <= 7 ? shift(year: current.0, month: current.1, by: -1) : current
    }

    /// Změna v procentech, `nil` = předtím nic.
    public static func pct(_ cur: Double, _ prev: Double) -> Int? {
        prev == 0 ? nil : Int(JS.round((cur - prev) / prev * 100))
    }

    /// Zajímavé postřehy v lidské řeči (`highlights`).
    public static func highlights(_ cur: PeriodStats, _ prev: PeriodStats, subjects: [Subject], clock: StudyClock) -> [String] {
        let name = { (id: String) in subjects.first { $0.id == id }?.name ?? "Smazaný předmět" }
        var out: [String] = []
        guard cur.sessions > 0 else { return out }
        if let change = pct(Double(cur.total), Double(prev.total)) {
            out.append(change >= 0
                ? "O \(change) % víc učení než v předchozím období (+\(Format.duration(cur.total - prev.total)))."
                : "O \(abs(change)) % méně učení než v předchozím období (−\(Format.duration(prev.total - cur.total))).")
        }
        if let best = cur.bestDay, let day = clock.parseDayKey(best.key) {
            out.append("Nejsilnější den: \(Format.date(day, .weekdayDayMonth, clock: clock)) – \(Format.duration(best.sec)).")
        }
        let topAvg = cur.weekdayAvg.max() ?? 0
        if let i = cur.weekdayAvg.firstIndex(of: topAvg), topAvg > 0 {
            out.append("Nejvíc se učíš \(weekdayIn[i]) – v průměru \(Format.duration(topAvg * 60)).")
        }
        let focused = cur.dayparts.enumerated().filter { $0.element.focus != nil && $0.element.min >= 30 }
            .sorted { a, b in a.element.focus! != b.element.focus! ? a.element.focus! > b.element.focus! : a.offset < b.offset }.map(\.element)
        if focused.count >= 2, let top = focused.first, let low = focused.last, top.focus! - low.focus! >= 0.3 {
            out.append("Nejlépe se soustředíš \(daypartWhen[top.label]!) (\(Format.decimal(top.focus!)) / 5), nejhůř \(daypartWhen[low.label]!) (\(Format.decimal(low.focus!))).")
        }
        // největší růst předmětu
        var grow: (id: String, diff: Int)?
        for s in cur.perSubject {
            let diff = s.sec - prev.secOf(subject: s.id)
            if grow.map({ diff > $0.diff }) ?? true { grow = (s.id, diff) }
        }
        if let grow, grow.diff >= 1800 { out.append("Největší posun: \(name(grow.id)) (+\(Format.duration(grow.diff))).") }
        let deep = Int(JS.round(cur.deepShare * 100))
        if cur.deepShare >= 0.5 {
            out.append("\(deep) % času připadlo na hluboké bloky nad 45 minut. Skvělé pro náročnou látku.")
        } else if cur.sessions >= 6 {
            out.append("Jen \(deep) % času bylo v blocích nad 45 minut. U náročné látky zkus delší bloky.")
        }
        if cur.consistency >= 0.7 {
            out.append("Učení v \(cur.activeDays) z \(cur.days) dní – výborná pravidelnost.")
        } else if cur.activeDays > 0 {
            out.append("Učení v \(cur.activeDays) z \(cur.days) dní. Pravidelné kratší učení funguje lépe než nárazovky.")
        }
        if let s = cur.longestSession { out.append("Nejdelší blok: \(Format.duration(s.durationSec)) (\(name(s.subjectId))).") }
        return out
    }
}

extension Stats {
    /// Nejdelší série dní od `from` do dne `until` včetně (`streakRuns` na webu, jen maximum).
    public static func longestRun(_ days: Set<String>, from: Int, until: Int, restDays: Int, clock: StudyClock) -> Int {
        let end = clock.startOfDay(until)
        var run = 0, best = 0, week = -1, rest = 0
        var t = clock.startOfDay(from)
        while t <= end {
            let w = clock.startOfWeek(t)
            if w != week {
                week = w
                rest = 0
            }
            if days.contains(clock.dayKey(t)) {
                run += 1
            } else if t == end {
                // dnešek ještě běží
            } else if run > 0 && rest < restDays {
                rest += 1
            } else {
                run = 0
            }
            best = max(best, run)
            t = clock.addDays(t, 1)
        }
        return best
    }
}
