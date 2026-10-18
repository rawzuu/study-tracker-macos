import Foundation

/// Kalendářní výpočty v místním čase (`src/lib/time.ts` na webu). Časy jsou v ms od epochy jako v datech.
/// Týden začíná pondělím; přičítání dnů drží místní čas i přes změnu času (jako `setDate` v JS).
public struct StudyClock: Sendable {
    public static let minute = 60_000
    public static let hour = 60 * minute
    public static let day = 24 * hour

    public let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.locale = Locale(identifier: "cs_CZ")
        calendar = c
    }

    public static var current: StudyClock { StudyClock() }

    public func date(_ t: Int) -> Date { Date(timeIntervalSince1970: Double(t) / 1000) }
    public func ms(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded()) }

    public func startOfDay(_ t: Int) -> Int { ms(calendar.startOfDay(for: date(t))) }

    /// Stejný místní čas o `n` dní později. Jako `setDate` v JS: čas, který při změně času neexistuje,
    /// se posune dopředu (2:30 → 3:30), a z dvakrát opakovaného času se bere první výskyt.
    public func addDays(_ t: Int, _ n: Int) -> Int {
        let millis = ((t % 1000) + 1000) % 1000
        var c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date(t - millis))
        c.day = (c.day ?? 0) + n
        return calendar.date(from: c).map { ms($0) + millis } ?? t + n * Self.day
    }

    /// Místní čas v sekundách od 1. 1. 1970 – posun pásma platný v daném okamžiku, takže i ve dnech změny
    /// času přesně. Den v týdnu, hodina a minuty se z něj počítají mnohem rychleji než přes kalendář
    /// (volají se pro každé sezení).
    func localSeconds(_ t: Int) -> Int {
        t.floorDiv(1000) + calendar.timeZone.secondsFromGMT(for: date(t))
    }

    /// 0 = pondělí … 6 = neděle (1. 1. 1970 byl čtvrtek).
    public func weekdayIndex(_ t: Int) -> Int {
        (localSeconds(t).floorDiv(86_400) + 3).floorMod(7)
    }

    public func startOfWeek(_ t: Int) -> Int {
        let day = startOfDay(t)
        return addDays(day, -weekdayIndex(day))
    }

    public func startOfMonth(_ t: Int) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date(t))
        return ms(calendar.date(from: c) ?? date(t))
    }

    /// Lokální klíč dne `YYYY-MM-DD`.
    public func dayKey(_ t: Int) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date(t))
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(c.year ?? 0)-\(pad(c.month ?? 0))-\(pad(c.day ?? 0))"
    }

    /// Půlnoc dne `YYYY-MM-DD` v místním čase.
    public func parseDayKey(_ key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])).map(ms)
    }

    /// Číslo týdne podle ISO 8601.
    public func isoWeek(_ t: Int) -> Int {
        calendar.component(.weekOfYear, from: date(t))
    }

    /// Okamžik `min` minut po půlnoci dne `day` podle místního času (`atMinutes` na webu; i ve dnech změny času).
    public func atMinutes(_ day: Int, _ min: Int) -> Int {
        var c = calendar.dateComponents([.year, .month, .day], from: date(day))
        c.hour = 0
        c.minute = min
        return calendar.date(from: c).map(ms) ?? startOfDay(day) + min * Self.minute
    }

    /// Minuty od půlnoci podle místního času (`h * 60 + m + s / 60` jako na webu).
    public func minutesOfDay(_ t: Int) -> Double {
        let sec = localSeconds(t).floorMod(86_400)
        return Double(sec / 3600 * 60 + sec % 3600 / 60) + Double(sec % 60) / 60
    }

    /// Hodina místního času (`getHours()` v JS).
    public func hour(_ t: Int) -> Int {
        localSeconds(t).floorMod(86_400) / 3600
    }

    /// Hodina místního času a začátek té další (`new Date(y, m, d, h + 1)` v JS) – i ve dnech změny času,
    /// kdy hodina trvá 0 nebo 2 hodiny skutečného času.
    func hourAndNext(_ t: Int) -> (hour: Int, next: Int) {
        let offset = calendar.timeZone.secondsFromGMT(for: date(t))
        let local = t.floorDiv(1000) + offset
        let h = local.floorMod(86_400) / 3600
        // Bez změny času do další celé hodiny stačí dopočítat; jinak rozhodne kalendář jako JS.
        let next = (local - local.floorMod(3600) + 3600 - offset) * 1000
        if calendar.timeZone.secondsFromGMT(for: date(next)) == offset { return (h, next) }
        var c = calendar.dateComponents([.year, .month, .day, .hour], from: date(t))
        c.hour = (c.hour ?? 0) + 1
        return (h, calendar.date(from: c).map(ms) ?? t + Self.hour)
    }
}

extension Int {
    /// Dělení zaokrouhlené dolů (i pro záporné hodnoty, časy před rokem 1970).
    func floorDiv(_ d: Int) -> Int { (self >= 0 ? self : self - d + 1) / d }
    func floorMod(_ d: Int) -> Int { ((self % d) + d) % d }
}
