import Core

/// Souhrny učení (`src/lib/stats.ts` na webu).
public enum Stats {
    /// Sezení, která začala v intervalu `[from, to)`.
    public static func inRange(_ sessions: [Session], from: Int, to: Int) -> [Session] {
        sessions.filter { $0.start >= from && $0.start < to }
    }

    public static func totalSec(_ sessions: [Session]) -> Int {
        sessions.reduce(0) { $0 + $1.durationSec }
    }

    /// Sekundy učení po dnech (klíč `YYYY-MM-DD`).
    public static func byDay(_ sessions: [Session], clock: StudyClock) -> [String: Int] {
        sessions.reduce(into: [:]) { $0[clock.dayKey($1.start), default: 0] += $1.durationSec }
    }

    public static func bySubject(_ sessions: [Session]) -> [String: Int] {
        sessions.reduce(into: [:]) { $0[$1.subjectId, default: 0] += $1.durationSec }
    }

    /// Dny, které se počítají do série (aspoň `minMin` minut učení).
    public static func streakDays(_ sessions: [Session], minMin: Int, clock: StudyClock) -> Set<String> {
        Set(byDay(sessions, clock: clock).filter { $0.value > 0 && $0.value >= minMin * 60 }.keys)
    }

    /// Aktuální a nejdelší série. Den bez učení sérii nepřeruší, pokud v daném týdnu (Po–Ne)
    /// ještě zbývá den volna (`restDays`); dnešek, který ještě neskončil, ji nepřeruší nikdy.
    public static func streaks(
        _ sessions: [Session], restDays: Int = 0, minMin: Int = 0, now: Int, clock: StudyClock
    ) -> (current: Int, best: Int) {
        let days = streakDays(sessions, minMin: minMin, clock: clock)
        guard let first = days.min().flatMap(clock.parseDayKey) else { return (0, 0) }
        let end = clock.startOfDay(now)
        var run = 0, best = 0, week = -1, rest = 0
        var t = clock.startOfDay(first)
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
        return (run, best)
    }

    /// Průměrné soustředění hodnocených sezení (1–5), `nil` = nic nehodnoceno.
    public static func avgFocus(_ sessions: [Session]) -> Double? {
        let rated = sessions.compactMap(\.focus).filter { $0 != 0 }
        guard !rated.isEmpty else { return nil }
        return Double(rated.reduce(0, +)) / Double(rated.count)
    }

    // MARK: - Denní doba

    /// Dvouhodinové okno dne, které začíná v hodině `from` (`to` = `from + 2`, přes půlnoc dokola).
    public struct HourWindow: Sendable, Hashable {
        public let from: Int
        public var to: Int { (from + 2) % 24 }
    }

    /// Čistý čas sezení rozpočítaný do hodin, přes které opravdu probíhalo (pauzy poměrně).
    static func forEachHour(_ s: some TimedStudy, clock: StudyClock, _ body: (_ t: Int, _ hour: Int, _ minutes: Double) -> Void) {
        let span = Double(max(1, s.end - s.start))
        let ratio = Double(s.durationSec * 1000) / span
        var t = s.start
        while t < s.end {
            let (hour, next) = clock.hourAndNext(t)
            let seg = min(next, s.end) - t
            body(t, hour, Double(seg) * ratio / 60_000)
            t += seg
        }
    }

    /// Matice [den v týdnu][hodina] s minutami učení (`hourWeekdayMatrix` na webu).
    public static func hourWeekdayMatrix(_ sessions: [some TimedStudy], clock: StudyClock) -> [[Double]] {
        var m = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for s in sessions {
            forEachHour(s, clock: clock) { t, hour, minutes in m[clock.weekdayIndex(t)][hour] += minutes }
        }
        return m
    }

    /// Minuty učení po hodinách dne (0–23).
    public static func byHour(_ sessions: [some TimedStudy], clock: StudyClock) -> [Double] {
        let m = hourWeekdayMatrix(sessions, clock: clock)
        return (0..<24).map { h in m.reduce(0) { $0 + $1[h] } }
    }

    /// Nejproduktivnější dvouhodinové okno podle minut učení.
    public static func bestWindow(_ sessions: [some TimedStudy], clock: StudyClock) -> HourWindow? {
        let h = byHour(sessions, clock: clock)
        var best = -1.0, at = 0
        for i in 0..<24 where h[i] + h[(i + 1) % 24] > best {
            best = h[i] + h[(i + 1) % 24]
            at = i
        }
        return best > 0 ? HourWindow(from: at) : nil
    }

    /// Nejsilnější dvouhodinové okno podle KVALITY soustředění (vážený průměr hodnocení 1–5). Málo dat v okně
    /// se „přitahuje“ k celkovému průměru (90 „virtuálních“ minut), aby nevyhrálo okno s jedním výborným blokem.
    /// Bez dostatku hodnocení rozhodne množství učení (`bestWindow`).
    public static func focusWindow(_ sessions: [some TimedStudy], clock: StudyClock) -> HourWindow? {
        let rated = sessions.filter { $0.focusValue != 0 && $0.mode != "anki" }
        guard rated.count >= 8 else { return bestWindow(sessions, clock: clock) }
        var min = Array(repeating: 0.0, count: 24)
        var fsum = Array(repeating: 0.0, count: 24)
        for s in rated {
            let focus = Double(s.focusValue)
            forEachHour(s, clock: clock) { _, hour, minutes in
                min[hour] += minutes
                fsum[hour] += minutes * focus
            }
        }
        let total = min.reduce(0, +)
        let g = fsum.reduce(0, +) / total
        let k = 90.0
        var best: (at: Int, score: Double)?
        for i in 0..<24 {
            let j = (i + 1) % 24
            let w = min[i] + min[j]
            if w < Swift.max(60, total * 0.05) { continue }
            let score = (fsum[i] + fsum[j] + k * g) / (w + k)
            if best == nil || score > best!.score { best = (i, score) }
        }
        return best.map { HourWindow(from: $0.at) } ?? bestWindow(sessions, clock: clock)
    }
}

/// Sezení, jak s ním počítají statistiky a doporučení – záznam z dat i jeho kompaktní kopie.
public protocol TimedStudy: Sendable {
    var start: Int { get }
    var end: Int { get }
    /// Čistý čas bez pauz.
    var durationSec: Int { get }
    /// Soustředění 1–5, 0 = nehodnoceno.
    var focusValue: Int { get }
    var mode: String { get }
}

extension Session: TimedStudy {
    public var focusValue: Int { focus ?? 0 }
}

/// Sezení zúžené na pole, se kterými počítají doporučení a ranní plán. Z JSON se čte jednou –
/// opakované čtení polí záznamu (slovník s textovými klíči) by bylo u tisíců sezení znát.
struct SessionFacts: TimedStudy {
    let subjectId: String, topic: String, mode: String
    let start: Int, end: Int, durationSec: Int
    let focusValue: Int

    init(_ s: Session) {
        subjectId = s.subjectId
        topic = s.topic
        mode = s.mode
        start = s.start
        end = s.end
        durationSec = s.durationSec
        focusValue = s.focus ?? 0
    }

    static func alive(in doc: AppDocument) -> [SessionFacts] {
        doc.alive(Session.self).map(SessionFacts.init)
    }
}
