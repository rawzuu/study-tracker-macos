import Foundation

/// Texty pro zobrazení – stejné tvary jako na webu (`fmtDuration`, `fmtTime`, `fmtDayLabel`…).
public enum Format {
    private static let cs = Locale(identifier: "cs_CZ")

    /// „2 h 15 min“, „45 min“, „30 s“, „0 min“ – jediný tvar délky v celé aplikaci.
    public static func duration(_ sec: Int) -> String {
        duration(Double(sec))
    }

    public static func duration(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded(.toNearestOrAwayFromZero)))
        let h = s / 3600
        let m = (s % 3600) / 60
        if h == 0 && m == 0 { return s > 0 ? "\(s) s" : "0 min" }
        if h == 0 { return "\(m) min" }
        return m > 0 ? "\(h) h \(m) min" : "\(h) h"
    }

    /// Desetinné číslo po česku s pevným počtem míst: „3,6“.
    public static func decimal(_ n: Double, digits: Int = 1) -> String {
        n.formatted(.number.locale(cs).precision(.fractionLength(digits)).rounded(rule: .toNearestOrAwayFromZero))
    }

    /// Počet po česku s mezerami po tisících: „12 345“ (`toLocaleString('cs-CZ')`).
    public static func count(_ n: Int) -> String {
        n.formatted(.number.locale(cs))
    }

    /// Hodiny nejvýš s jedním desetinným místem: „3,5 h“.
    public static func hours(_ sec: Int) -> String {
        (Double(sec) / 3600).formatted(.number.locale(cs).precision(.fractionLength(0...1)).rounded(rule: .toNearestOrAwayFromZero)) + " h"
    }

    /// Čas „09:05“.
    public static func time(_ t: Int, clock: StudyClock) -> String {
        let c = clock.calendar.dateComponents([.hour, .minute], from: clock.date(t))
        return two(c.hour ?? 0) + ":" + two(c.minute ?? 0)
    }

    /// Odpočet „24:13“ nebo „1:02:05“.
    public static func clock(ms: Int) -> String {
        let total = max(0, Int((Double(ms) / 1000).rounded(.toNearestOrAwayFromZero)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(two(m)):\(two(s))"
    }

    /// Tvary data, které web používá (`fmtDate` / `toLocaleDateString('cs-CZ', …)`).
    public enum DateStyle: String, CaseIterable, Sendable {
        /// „čtvrtek 8. října“
        case weekdayDayMonth
        /// „čt 8. 10.“
        case shortWeekdayDayNumericMonth
        /// „8. 10.“
        case dayNumericMonth
        /// „8. 10. 2026“
        case dayNumericMonthYear
        /// „8. 10. 26“
        case dayNumericMonthShortYear
        /// „8. října“
        case dayMonth
        /// „čt 8. října“
        case shortWeekdayDayMonth
        /// „čtvrtek 8. 10.“
        case weekdayDayNumericMonth
        /// „říjen 26“
        case monthShortYear
        /// „říjen 2026“
        case monthYear
    }

    public static func date(_ t: Int, _ style: DateStyle, clock: StudyClock) -> String {
        let c = clock.calendar.dateComponents([.year, .month, .day], from: clock.date(t))
        let y = c.year ?? 0, m = c.month ?? 1, d = c.day ?? 0
        let wd = clock.weekdayIndex(t)
        return switch style {
        case .weekdayDayMonth: "\(weekdaysLong[wd]) \(d). \(monthsGenitive[m - 1])"
        case .shortWeekdayDayNumericMonth: "\(weekdaysLower[wd]) \(d). \(m)."
        case .dayNumericMonth: "\(d). \(m)."
        case .dayNumericMonthYear: "\(d). \(m). \(y)"
        case .dayNumericMonthShortYear: "\(d). \(m). \(two(y % 100))"
        case .dayMonth: "\(d). \(monthsGenitive[m - 1])"
        case .shortWeekdayDayMonth: "\(weekdaysLower[wd]) \(d). \(monthsGenitive[m - 1])"
        case .weekdayDayNumericMonth: "\(weekdaysLong[wd]) \(d). \(m)."
        case .monthShortYear: "\(months[m - 1]) \(two(y % 100))"
        case .monthYear: "\(months[m - 1]) \(y)"
        }
    }

    /// „Dnes“, „Včera“, „Zítra“, jinak „čtvrtek 8. října“.
    public static func dayLabel(_ t: Int, now: Int, clock: StudyClock) -> String {
        let today = clock.startOfDay(now)
        let d = clock.startOfDay(t)
        if d == today { return "Dnes" }
        if d == clock.addDays(today, -1) { return "Včera" }
        if d == clock.addDays(today, 1) { return "Zítra" }
        return date(t, .weekdayDayMonth, clock: clock)
    }

    /// První písmeno velké („čtvrtek 8. října“ → „Čtvrtek 8. října“).
    public static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Sklonování: `plural(3, "den", "dny", "dní")`.
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if n == 1 { return one }
        if (2...4).contains(n) { return few }
        return many
    }

    public static let weekdaysShort = ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"]
    public static let weekdaysLong = ["pondělí", "úterý", "středa", "čtvrtek", "pátek", "sobota", "neděle"]
    private static let weekdaysLower = ["po", "út", "st", "čt", "pá", "so", "ne"]
    /// Měsíce v 1. pádě („říjen 2026“) a ve 2. pádě („8. října“).
    public static let months = ["leden", "únor", "březen", "duben", "květen", "červen", "červenec", "srpen", "září", "říjen", "listopad", "prosinec"]
    private static let monthsGenitive = ["ledna", "února", "března", "dubna", "května", "června", "července", "srpna", "září", "října", "listopadu", "prosince"]
    public static let focusLabels = ["", "Rozptýlený", "Spíš slabé", "V pohodě", "Soustředěný", "Hluboký flow"]

    /// Název režimu časovače (`modeName` na webu).
    public static func modeName(_ id: String, presets: [String: String] = [:]) -> String {
        switch id {
        case "manual": "Ruční zápis"
        case "plan": "Z plánu"
        case "anki": "Anki"
        case "pomodoro": "Pomodoro"
        case "pomodoro-long": "Dlouhé Pomodoro"
        case "52-17": "52 / 17"
        case "ultradian": "Ultradiánní blok"
        case "flowtime": "Flowtime"
        case "stopwatch": "Stopky"
        default: presets[id] ?? "Neznámý režim"
        }
    }

    private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
