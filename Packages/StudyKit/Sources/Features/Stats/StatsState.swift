import Core
import Engine
import Foundation

/// Období statistik (`PERIODS` v `StatsPage.tsx`).
public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "7", month = "30", quarter = "90", year = "365", all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: "7 dní"
        case .month: "30 dní"
        case .quarter: "3 měs."
        case .year: "Rok"
        case .all: "Vše"
        }
    }

    /// Delší popis do věty („za posledních 30 dní“).
    var phrase: String {
        switch self {
        case .week: "za posledních 7 dní"
        case .month: "za posledních 30 dní"
        case .quarter: "za poslední 3 měsíce"
        case .year: "za poslední rok"
        case .all: "od začátku"
        }
    }
}

/// Stránka Statistiky (`StatsPage` na webu): stejná čísla, stejné období a srovnání s předchozím obdobím.
/// Čistá funkce dokument → zobrazení, testovaná bez UI.
public struct StatsState: Sendable {
    public struct SubjectRow: Identifiable, Sendable, Hashable {
        public let subject: SubjectInfo
        public let sec: Int
        /// Podíl na celku v procentech (zaokrouhleně jako na webu).
        public let percent: Int
        public let sessions: Int
        public let avgSec: Double
        public let focus: Double?
        public var id: String { subject.id }
    }

    /// Den v grafu vývoje.
    public struct DayValue: Identifiable, Sendable, Hashable {
        public let day: Int
        public let minutes: Double
        public var id: Int { day }
    }

    /// Úsek grafu „Předměty v čase“ (týden nebo měsíc) a minuty jednoho předmětu v něm.
    public struct BucketValue: Identifiable, Sendable, Hashable {
        public let bucket: Int
        public let label: String
        public let subject: SubjectInfo
        public let minutes: Double
        public var id: String { "\(bucket)-\(subject.id)" }
    }

    public struct HourValue: Identifiable, Sendable, Hashable {
        public let hour: Int
        public let minutes: Double
        public let focus: Double?
        public var id: Int { hour }
    }

    public let isEmpty: Bool
    public let period: StatsPeriod
    public let totalSec: Int
    /// Změna proti předchozímu stejně dlouhému období v %, `nil` = není s čím srovnat.
    public let change: Int?
    public let days: Int
    public let activeDays: Int
    public let perDaySec: Double
    /// Bloky bez Anki (krátké bloky z Anki průměr nezkreslují).
    public let blocks: Int
    public let ankiBlocks: Int
    public let avgBlockSec: Double
    public let focus: Double?
    public let peak: Stats.HourWindow?
    public let subjects: [SubjectRow]
    public let trend: [DayValue]
    /// Denní cíl jako vodorovná čára (jen bez filtru předmětu).
    public let goalMinutes: Int
    public let stacked: [BucketValue]
    public let byMonths: Bool
    /// Minuty po dnech týdne (0 = pondělí) × hodinách.
    public let weekHour: [[Double]]
    public let hours: [HourValue]
    /// Posledních 365 dní (pro „Celý rok“), jen podle filtru předmětu.
    public let year: [DayValue]
    public let insights: [String]

    public init(document doc: AppDocument, period: StatsPeriod, subjectId: String?, now: Int, clock: StudyClock) {
        let all = doc.alive(Session.self)
        let matches = { (s: Session) in subjectId == nil || s.subjectId == subjectId }
        let lookup = SubjectLookup(doc)
        let end = clock.addDays(clock.startOfDay(now), 1)
        let first = all.reduce(now) { min($0, $1.start) }
        let from = period == .all ? clock.startOfDay(first) : clock.addDays(end, -Int(period.rawValue)!)
        let filtered = Stats.inRange(all, from: from, to: end).filter(matches)
        let prev = Stats.inRange(all, from: from - (end - from), to: from).filter(matches)

        isEmpty = all.isEmpty
        self.period = period
        let total = Stats.totalSec(filtered)
        let prevTotal = Stats.totalSec(prev)
        totalSec = total
        change = prevTotal > 0 ? Int(JS.round(Double(total - prevTotal) / Double(prevTotal) * 100)) : nil
        let days = max(1, Int(JS.round(Double(end - from) / Double(StudyClock.day))))
        self.days = days
        activeDays = Set(filtered.map { clock.dayKey($0.start) }).count
        perDaySec = Double(total) / Double(days)
        let blockList = filtered.filter { $0.mode != "anki" }
        blocks = blockList.count
        ankiBlocks = filtered.count - blockList.count
        avgBlockSec = blockList.isEmpty ? 0 : Double(Stats.totalSec(blockList)) / Double(blockList.count)
        focus = Stats.avgFocus(filtered)
        peak = Stats.bestWindow(filtered, clock: clock)

        // Předměty od nejvíc (při shodě v pořadí, v jakém se objevily – `Map` na webu a stabilní řazení)
        var order: [String] = []
        var secBySubject: [String: Int] = [:]
        var listBySubject: [String: [Session]] = [:]
        for s in filtered {
            if secBySubject[s.subjectId] == nil { order.append(s.subjectId) }
            secBySubject[s.subjectId, default: 0] += s.durationSec
            listBySubject[s.subjectId, default: []].append(s)
        }
        let ranked = order.enumerated().sorted { a, b in
            let x = secBySubject[a.element]!, y = secBySubject[b.element]!
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        subjects = ranked.map { id in
            let sec = secBySubject[id]!, list = listBySubject[id]!
            return SubjectRow(subject: lookup[id], sec: sec, percent: Int(JS.round(Double(sec) / Double(max(1, total)) * 100)),
                              sessions: list.count, avgSec: Double(sec) / Double(list.count), focus: Stats.avgFocus(list))
        }

        let perDay = Stats.byDay(filtered, clock: clock)
        let trendDays = min(days, 90)
        trend = (0..<trendDays).reversed().map { i in
            let t = clock.addDays(end, -i - 1)
            return DayValue(day: t, minutes: Double(perDay[clock.dayKey(t)] ?? 0) / 60)
        }
        goalMinutes = subjectId == nil ? doc.settings.dailyGoalMin : 0

        // Předměty v čase: po týdnech, u delšího období (přes 120 dní) po měsících
        byMonths = days > 120
        var buckets: [(start: Int, label: String)] = []
        if byMonths {
            var t = clock.startOfMonth(from)
            while t < end {
                buckets.append((t, Format.date(t, .monthShortYear, clock: clock)))
                t = clock.startOfMonth(clock.addDays(t, 32))
            }
        } else {
            var t = clock.startOfWeek(from)
            while t < end {
                buckets.append((t, Format.date(t, .dayNumericMonth, clock: clock)))
                t = clock.addDays(t, 7)
            }
        }
        var perBucket: [String: [Double]] = [:]
        var bucketOrder: [String] = []
        for s in filtered {
            var i = buckets.count - 1
            while i > 0 && buckets[i].start > s.start { i -= 1 }
            if perBucket[s.subjectId] == nil {
                bucketOrder.append(s.subjectId)
                perBucket[s.subjectId] = Array(repeating: 0, count: buckets.count)
            }
            perBucket[s.subjectId]![i] += Double(s.durationSec) / 60
        }
        let series = bucketOrder.enumerated().sorted { a, b in
            let x = perBucket[a.element]!.reduce(0, +), y = perBucket[b.element]!.reduce(0, +)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        stacked = series.flatMap { id in
            buckets.indices.map { BucketValue(bucket: $0, label: buckets[$0].label, subject: lookup[id], minutes: perBucket[id]![$0]) }
        }

        weekHour = Stats.hourWeekdayMatrix(filtered, clock: clock)
        let minutesByHour = Stats.byHour(filtered, clock: clock)
        let focusByHour = Self.focusByHour(filtered, clock: clock)
        hours = (0..<24).map { HourValue(hour: $0, minutes: minutesByHour[$0], focus: focusByHour[$0]) }

        let yearPerDay = Stats.byDay(all.filter(matches), clock: clock)
        let today = clock.startOfDay(now)
        year = (0..<365).reversed().map { i in
            let t = clock.addDays(today, -i)
            return DayValue(day: t, minutes: JS.round(Double(yearPerDay[clock.dayKey(t)] ?? 0) / 60))
        }
        insights = Self.insights(filtered, perDay: perDay, clock: clock)
    }

    /// Průměrné soustředění podle hodiny začátku sezení (`focusByHour`).
    static func focusByHour(_ sessions: [Session], clock: StudyClock) -> [Double?] {
        var sum = Array(repeating: 0.0, count: 24), count = Array(repeating: 0, count: 24)
        for s in sessions {
            guard let f = s.focus, f != 0 else { continue }
            let h = clock.hour(s.start)
            sum[h] += Double(f)
            count[h] += 1
        }
        return (0..<24).map { count[$0] > 0 ? sum[$0] / Double(count[$0]) : nil }
    }

    /// Krátké, daty podložené postřehy (`Insights` na webu).
    static func insights(_ list: [Session], perDay: [String: Int], clock: StudyClock) -> [String] {
        guard list.count >= 5 else { return [] }
        var tips: [String] = []
        let long = list.filter { $0.durationSec >= 45 * 60 && ($0.focus ?? 0) != 0 }
        let short = list.filter { $0.durationSec < 45 * 60 && ($0.focus ?? 0) != 0 }
        if let fl = Stats.avgFocus(long), let fs = Stats.avgFocus(short), long.count >= 3, short.count >= 3, abs(fl - fs) >= 0.4 {
            tips.append(fl > fs
                ? "U delších bloků (45+ min) máš vyšší soustředění (\(Format.decimal(fl)) vs \(Format.decimal(fs))). Zkus Dlouhé Pomodoro nebo Flowtime."
                : "U kratších bloků máš vyšší soustředění (\(Format.decimal(fs)) vs \(Format.decimal(fl))). Klasické Pomodoro ti asi sedí víc.")
        }
        let late = list.filter { clock.hour($0.start) >= 22 }
        if Double(late.count) / Double(list.count) > 0.3 {
            tips.append("Víc než 30 % učení máš po 22. hodině. Spánek je klíčový pro ukládání do paměti – zkus část přesunout dřív.")
        }
        let days = Set(list.map { clock.dayKey($0.start) })
        if days.count <= 3, (perDay.values.max() ?? 0) > 4 * 3600 {
            tips.append("Učení máš nahuštěné do pár dní. Rozložené opakování vede k výrazně lepšímu dlouhodobému zapamatování než „nárazovka“.")
        }
        if Double(list.filter { $0.interruptions > 0 }.count) / Double(list.count) > 0.5 {
            tips.append("Ve více než polovině bloků tě něco vyrušilo. Zkus mobil do jiné místnosti a vypnout notifikace.")
        }
        return tips
    }
}
