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

    public func addDays(_ t: Int, _ n: Int) -> Int {
        ms(calendar.date(byAdding: .day, value: n, to: date(t)) ?? date(t + n * Self.day))
    }

    /// 0 = pondělí … 6 = neděle
    public func weekdayIndex(_ t: Int) -> Int {
        (calendar.component(.weekday, from: date(t)) + 5) % 7
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

    /// Minuty od půlnoci podle místního času.
    public func minutesOfDay(_ t: Int) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date(t))
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }
}
