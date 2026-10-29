import Engine
import Focus
import Foundation

/// Statistiky Soustředění za posledních `days` dní: čas u obrazovky, pokusy, odemknutí a porušení.
public struct FocusStats: Sendable, Equatable {
    public struct Day: Sendable, Equatable, Identifiable {
        public var key: String
        /// Půlnoc dne.
        public var start: Int
        public var screenMs: Int
        public var attempts: Int
        public var id: String { key }
    }

    /// Aplikace, nebo web (doména v prohlížeči).
    public struct Item: Sendable, Equatable, Identifiable {
        public var name: String
        public var isSite: Bool
        public var ms: Int
        public var id: String { (isSite ? "site:" : "app:") + name }
    }

    public struct Target: Sendable, Equatable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name }
    }

    public var days: [Day]
    /// Nejvíc času (aplikace bez domény; Safari s doménou jako web).
    public var top: [Item]
    public var topAttempts: [Target]
    /// Pokusy podle dne v týdnu (0 = pondělí) a hodiny.
    public var heatmap: [[Int]]
    public var unlocks: Int
    public var tamper: [FocusEvent]

    public var screenMs: Int { days.reduce(0) { $0 + $1.screenMs } }
    public var attempts: Int { days.reduce(0) { $0 + $1.attempts } }

    public static func make(usage: [UsageRow], events: [FocusEvent], days count: Int, now: Int, clock: StudyClock, topCount: Int = 10) -> FocusStats {
        let today = clock.startOfDay(now)
        let starts = (0..<max(1, count)).reversed().map { clock.addDays(today, -$0) }
        var days = starts.map { Day(key: clock.dayKey($0), start: $0, screenMs: 0, attempts: 0) }
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.key, $0) })

        var items: [String: Item] = [:]
        for row in usage {
            guard let i = index[row.day] else { continue }
            days[i].screenMs += row.ms
            let isSite = !row.host.isEmpty
            let item = Item(name: isSite ? row.host : row.appName, isSite: isSite, ms: row.ms)
            items[item.id, default: Item(name: item.name, isSite: isSite, ms: 0)].ms += row.ms
        }

        var heatmap = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var targets: [String: Int] = [:]
        var unlocks = 0
        var tamper: [FocusEvent] = []
        let first = starts.first ?? today
        for e in events where e.at >= first {
            switch e.kind {
            case .attempt:
                if let i = index[clock.dayKey(e.at)] { days[i].attempts += 1 }
                heatmap[clock.weekdayIndex(e.at)][clock.hour(e.at)] += 1
                targets[e.name, default: 0] += 1
            case .unlock: unlocks += 1
            case .tamper: tamper.append(e)
            }
        }
        return FocusStats(
            days: days,
            top: Array(items.values.sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.name < $1.name }.prefix(topCount)),
            topAttempts: Array(targets.map { Target(name: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }.prefix(topCount)),
            heatmap: heatmap, unlocks: unlocks, tamper: tamper.sorted { $0.at > $1.at })
    }
}

extension FocusStats {
    /// Věta do pondělního souhrnu: „Soustředění: u obrazovky 31 h 20 min, 23 pokusů o rozptýlení (nejčastěji youtube.com).“
    /// `nil`, když za týden nic není.
    public var weeklyLine: String? {
        guard screenMs > 0 || attempts > 0 else { return nil }
        var parts: [String] = []
        if screenMs > 0 { parts.append("u obrazovky \(Format.duration(screenMs / 1000))") }
        if attempts > 0 {
            let noun = attempts == 1 ? "pokus" : attempts < 5 ? "pokusy" : "pokusů"
            parts.append("\(attempts) \(noun) o rozptýlení" + (topAttempts.first.map { " (nejčastěji \($0.name))" } ?? ""))
        }
        return "Soustředění: " + parts.joined(separator: ", ") + "."
    }
}
