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
}

extension Topic {
    /// Téma je na řadě před koncem dne `dayEnd` (`isDue` na webu).
    public func isDue(before dayEnd: Int) -> Bool {
        !isDeleted && !mastered && (nextReviewAt.map { $0 < dayEnd } ?? false)
    }

    /// Kolik dní je po termínu (záporné = do termínu).
    public func overdueDays(now: Int, clock: StudyClock) -> Int {
        guard let next = nextReviewAt else { return 0 }
        // `Math.round` v JS zaokrouhluje polovinu nahoru (i u záporných čísel).
        return Int((Double(clock.startOfDay(now) - clock.startOfDay(next)) / Double(StudyClock.day) + 0.5).rounded(.down))
    }
}
