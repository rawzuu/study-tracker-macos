import Core
import Foundation

/// Kalibrace cílů a plánu podle skutečnosti – návrhy v měsíčním reportu (`src/lib/calibrate.ts` na webu).
///
/// Data z posledních 8 týdnů, novější dny váží víc (poločas 14 dní). Návrh vzniká, jen když se realita
/// od nastavení dlouhodobě liší, a změna je omezená (nejvýš ±30 % za měsíc):
///  - denní cíl má být splnitelný zhruba v 70 % studijních dní (návrh pod 45 % nebo nad 85 %),
///  - týdenní cíle předmětů se při dlouhodobém neplnění sníží (nebo při velké rezervě zvýší) poměrně,
///  - časové okno ranního plánu podle toho, kdy se opravdu učíš (10.–90. percentil).
public enum Calibrate {
    public enum Key: String, CaseIterable, Sendable { case dailyGoal, weeklyGoals, dayWindow }

    public struct Suggestion: Sendable, Hashable, Identifiable {
        public let key: Key
        public let title: String
        public let current: String
        public let proposed: String
        public let reasons: [String]
        /// Změna nastavení (`dailyGoalMin`, nebo `planDayStart` a `planDayEnd`).
        public let settings: JSONObject
        /// Nové týdenní cíle předmětů.
        public let subjects: [(id: String, weeklyGoalMin: Int)]
        public let before: JSONValue
        public let after: JSONValue
        public var id: String { key.rawValue }

        public static func == (a: Suggestion, b: Suggestion) -> Bool {
            a.key == b.key && a.reasons == b.reasons && a.before == b.before && a.after == b.after
        }

        public func hash(into h: inout Hasher) { h.combine(key) }
    }

    static let lookbackDays = 56
    static let halfLifeDays = 14.0
    static let maxStep = 0.3

    static func recency(_ end: Int, _ t: Int) -> Double { pow(0.5, Double(end - t) / (halfLifeDays * Double(StudyClock.day))) }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    static func round15(_ min: Double) -> Double { JS.round(min / 15) * 15 }
    static func fmtMin(_ min: Double) -> String { Format.duration(min * 60) }
    static func hm(_ min: Double) -> String {
        let m = Int(JS.round(min.truncatingRemainder(dividingBy: 60)))
        return "\(Int((min / 60).rounded(.down)) % 24):\(m < 10 ? "0" : "")\(m)"
    }

    static func toMin(_ v: String) -> Double {
        let parts = v.split(separator: ":", omittingEmptySubsequences: false).map { ICal.jsNumber(String($0)) }
        let h = parts.first.flatMap { $0 } ?? 0, m = parts.count > 1 ? parts[1] ?? 0 : 0
        return (h.isNaN ? 0 : h) * 60 + (m.isNaN ? 0 : m)
    }

    static func pad(_ min: Int) -> String {
        let h = min / 60, m = min % 60
        return "\(h < 10 ? "0" : "")\(h):\(m < 10 ? "0" : "")\(m)"
    }

    /// Vážený kvantil (`weightedQuantile`): hodnoty seřazené stabilně, váhy se sčítají do `q`.
    public static func weightedQuantile(_ values: [Double], _ weights: [Double], _ q: Double) -> Double {
        let pairs = Array(zip(values, weights)).stableSorted { $0.0 < $1.0 }
        let total = pairs.reduce(0) { $0 + $1.1 }
        var acc = 0.0
        for (v, w) in pairs {
            acc += w
            if acc >= q * total - 1e-9 { return v }
        }
        return pairs.last?.0 ?? 0
    }

    /// Návrhy úprav k datu `end` (konec měsíce reportu) – jen ty, které mají oporu v datech.
    public static func suggestions(_ doc: AppDocument, end: Int, clock: StudyClock) -> [Suggestion] {
        [dailyGoal(doc, end: end, clock: clock), weeklyGoals(doc, end: end, clock: clock), dayWindow(doc, end: end, clock: clock)].compactMap { $0 }
    }

    /// Je dost dat (aspoň 10 studijních dní za 8 týdnů)?
    public static func enoughData(_ doc: AppDocument, end: Int, clock: StudyClock) -> Bool {
        let from = clock.addDays(clock.startOfDay(end - 1), -(lookbackDays - 1))
        let perDay = Stats.byDay(doc.alive(Session.self).filter { $0.start >= from && $0.start < end }, clock: clock)
        return perDay.values.filter { $0 >= 300 }.count >= 10
    }

    /// `YYYY-MM` (měsíc 0–11).
    public static func monthKey(year: Int, month: Int) -> String {
        "\(year)-\(month + 1 < 10 ? "0" : "")\(month + 1)"
    }

    // MARK: - Denní cíl

    static func dailyGoal(_ doc: AppDocument, end: Int, clock: StudyClock) -> Suggestion? {
        let goal = Double(doc.settings.dailyGoalMin)
        guard goal > 0 else { return nil } // 0 = vědomě bez cíle
        let lastDay = clock.startOfDay(end - 1)
        let firstDay = clock.addDays(lastDay, -(lookbackDays - 1))
        let perDay = Stats.byDay(doc.alive(Session.self).filter { $0.start >= firstDay && $0.start < end }, clock: clock)
        var days: [(min: Double, w: Double)] = []
        var d = firstDay
        while d <= lastDay {
            let min = Double(perDay[clock.dayKey(d)] ?? 0) / 60
            if min >= 5 { days.append((min, recency(end, d))) }
            d = clock.addDays(d, 1)
        }
        guard days.count >= 10 else { return nil }
        let wSum = days.reduce(0) { $0 + $1.w }
        let hit = days.reduce(0) { $0 + ($1.min >= goal ? $1.w : 0) } / wSum
        if hit >= 0.45 && hit <= 0.85 { return nil }

        let raw = weightedQuantile(days.map(\.min), days.map(\.w), 0.3)
        let step = max(15, goal * maxStep)
        let capped = clamp(raw, goal - step, goal + step)
        // zaokrouhlit na 15 min směrem k původnímu cíli, aby krok nepřekročil limit
        let proposed = max(30, capped < goal ? (capped / 15).rounded(.up) * 15 : (capped / 15).rounded(.down) * 15)
        if abs(proposed - goal) < max(15, goal * 0.1) { return nil }

        let met = days.filter { $0.min >= goal }.count
        let median = weightedQuantile(days.map(\.min), days.map { _ in 1 }, 0.5)
        let typical = round15(median)
        var reasons = ["Cíl \(fmtMin(goal)) byl splněn v \(met) z \(days.count) studijních dní za posledních 8 týdnů.",
                       "Typický studijní den: \(fmtMin(typical != 0 ? typical : median))."]
        let blocks = doc.alive(PlanBlock.self).filter { $0.start >= firstDay && $0.start < end }
        if blocks.count >= 5 {
            reasons.append("Z naplánovaných bloků se uskutečnilo \(Int(JS.round(Double(blocks.filter(\.done).count) / Double(blocks.count) * 100))) %.")
        }
        reasons.append(proposed < goal
            ? "Nový cíl by se splnil zhruba v 7 z 10 dní – pořád táhne nahoru, ale nepůsobí jako předem prohraný. Ranní plán podle něj navrhne reálné množství."
            : "Cíl se plní skoro pokaždé, o kousek vyšší posune dál.")
        if capped != raw { reasons.append("Změna je za měsíc omezená, případné doladění přijde příště.") }
        return Suggestion(key: .dailyGoal, title: "Denní cíl", current: fmtMin(goal), proposed: fmtMin(proposed), reasons: reasons,
                          settings: ["dailyGoalMin": .number(proposed)], subjects: [], before: .number(goal), after: .number(proposed))
    }

    // MARK: - Týdenní cíle předmětů

    static func weeklyGoals(_ doc: AppDocument, end: Int, clock: StudyClock) -> Suggestion? {
        let goals = doc.alive(Subject.self).filter { !$0.archived && $0.weeklyGoalMin > 0 }
        guard !goals.isEmpty else { return nil }
        let G = Double(goals.reduce(0) { $0 + $1.weeklyGoalMin })
        let sessions = doc.alive(Session.self)
        let lastWeek = clock.startOfWeek(end) // první neúplný týden se nepočítá
        var weeks: [(coverage: Double, total: Double, per: [String: Double], w: Double)] = []
        for i in 1...6 {
            let from = clock.addDays(lastWeek, -7 * i)
            let to = clock.addDays(from, 7)
            let list = sessions.filter { $0.start >= from && $0.start < to }
            guard !list.isEmpty else { continue }
            var per: [String: Double] = [:]
            for s in list { per[s.subjectId, default: 0] += Double(s.durationSec) / 60 }
            let covered = goals.reduce(0.0) { $0 + min(per[$1.id] ?? 0, Double($1.weeklyGoalMin)) }
            let total = goals.reduce(0.0) { $0 + (per[$1.id] ?? 0) }
            weeks.append((covered / G, total / G, per, recency(end, to)))
        }
        guard weeks.count >= 3 else { return nil }
        let wSum = weeks.reduce(0) { $0 + $1.w }
        let C = weeks.reduce(0) { $0 + $1.coverage * $1.w } / wSum
        let T = weightedQuantile(weeks.map(\.total), weeks.map(\.w), 0.5)

        let f: Double
        if C < 0.6 {
            f = clamp(T, 1 - maxStep, 0.9)
        } else if C >= 0.95 && T >= 1.25 {
            f = clamp(T * 0.9, 1.1, 1 + maxStep)
        } else {
            return nil
        }
        let next = goals.map { (id: $0.id, weeklyGoalMin: Int(max(15, round15(Double($0.weeklyGoalMin) * f)))) }
        if zip(next, goals).allSatisfy({ $0.weeklyGoalMin == $1.weeklyGoalMin }) { return nil }
        let newG = Double(next.reduce(0) { $0 + $1.weeklyGoalMin })

        var reasons = ["Cíle předmětů dávají dohromady \(fmtMin(G)) týdně, odučí se typicky kolem \(fmtMin(round15(T * G))).",
                       "Za posledních \(weeks.count) týdnů se v průměru splnilo \(Int(JS.round(C * 100))) % cílů."]
        if f < 1 {
            // Kolik cíle předmět v průměru plní (vážené jako C).
            var shares: [(subject: Subject, share: Double)] = []
            for s in goals {
                var sum = 0.0
                for week in weeks {
                    let done: Double = week.per[s.id] ?? 0
                    sum += min(1, done / Double(s.weeklyGoalMin)) * week.w
                }
                shares.append((s, sum / wSum))
            }
            let behind = Array(shares.filter { $0.share < 0.5 }.stableSorted { $0.share < $1.share }.prefix(2))
            if !behind.isEmpty {
                let names = behind.map { "\($0.subject.name) (\(Int(JS.round($0.share * 100))) %)" }
                reasons.append("Nejvíc zaostává: \(names.joined(separator: ", ")).")
            }
        }
        reasons.append("Všechny cíle se upraví poměrně – pořadí důležitosti předmětů zůstane stejné.")
        var before = JSONObject(), after = JSONObject()
        for s in goals { before[s.id] = .number(Double(s.weeklyGoalMin)) }
        for n in next { after[n.id] = .number(Double(n.weeklyGoalMin)) }
        return Suggestion(key: .weeklyGoals, title: "Týdenní cíle předmětů", current: "\(fmtMin(G)) týdně", proposed: "\(fmtMin(newG)) týdně",
                          reasons: reasons, settings: [:], subjects: next, before: .object(before), after: .object(after))
    }

    // MARK: - Časové okno ranního plánu

    static func dayWindow(_ doc: AppDocument, end: Int, clock: StudyClock) -> Suggestion? {
        let from = clock.addDays(clock.startOfDay(end - 1), -(lookbackDays - 1))
        let list = doc.alive(Session.self).filter { $0.start >= from && $0.start < end && $0.mode != "anki" && $0.end > $0.start }
        guard list.count >= 15 else { return nil }
        let late = { (m: Double) in m < 4 * 60 ? m + 24 * 60 : m } // učení po půlnoci patří k večeru
        let w = list.map { recency(end, $0.start) }
        let starts = list.map { late(clock.minutesOfDay($0.start)) }
        let ends = list.map { s in
            let m = clock.minutesOfDay(s.end)
            return clock.startOfDay(s.end) > clock.startOfDay(s.start) || m < 4 * 60 ? m + 24 * 60 : m
        }
        let p10 = weightedQuantile(starts, w, 0.1)
        let p90 = weightedQuantile(ends, w, 0.9)
        let settings = doc.settings
        let startText = settings.raw.string("planDayStart"), endText = settings.raw.string("planDayEnd")
        let curStart = toMin(startText ?? "08:00"), curEnd = toMin(endText ?? "22:00")
        var newStart = clamp((p10 / 30).rounded(.down) * 30, 5 * 60, 14 * 60)
        var newEnd = clamp((p90 / 30).rounded(.up) * 30, newStart + 4 * 60, 23 * 60 + 30)
        // Okno se nezužuje tam, kde se naplánované bloky z velké části opravdu plní – plán tam funguje.
        let blocks = doc.alive(PlanBlock.self).filter { $0.start >= from && $0.start < end }
        let doneRate = { (l: [PlanBlock]) -> Double? in l.count >= 3 ? Double(l.filter(\.done).count) / Double(l.count) : nil }
        let early = blocks.filter { clock.minutesOfDay($0.start) < newStart }
        let lateBlocks = blocks.filter { clock.minutesOfDay($0.start) >= newEnd }
        if newStart > curStart && (doneRate(early) ?? 0) >= 0.5 { newStart = curStart }
        if newEnd < curEnd && (doneRate(lateBlocks) ?? 0) >= 0.5 { newEnd = curEnd }
        if abs(newStart - curStart) < 60 && abs(newEnd - curEnd) < 60 { return nil }

        var reasons = ["80 % učení za posledních 8 týdnů probíhá mezi \(hm(p10)) a \(hm(p90))."]
        if newStart - curStart >= 60 && early.count >= 3 {
            reasons.append("Z bloků naplánovaných před \(hm(newStart)) se uskutečnilo \(Int(JS.round(doneRate(early)! * 100))) %.")
        }
        if curStart - newStart >= 60 { reasons.append("Část učení probíhá už před \(hm(curStart)), kam ranní plán teď nic nedává.") }
        if newEnd - curEnd >= 60 { reasons.append("Část učení probíhá i po \(hm(curEnd)), kam ranní plán teď nic nedává.") }
        if curEnd - newEnd >= 60 {
            reasons.append(lateBlocks.count >= 3
                ? "Z bloků naplánovaných po \(hm(newEnd)) se uskutečnilo jen \(Int(JS.round(doneRate(lateBlocks)! * 100))) %."
                : "Po \(hm(newEnd)) se učíš jen výjimečně, ranní plán tam ale bloky nabízí.")
        }
        reasons.append("Ranní plán pak bude navrhovat bloky v hodinách, kdy se opravdu učíš.")
        var before = JSONObject()
        before["start"] = startText.map(JSONValue.string)
        before["end"] = endText.map(JSONValue.string)
        let after: JSONObject = ["start": .string(pad(Int(newStart))), "end": .string(pad(Int(newEnd)))]
        return Suggestion(key: .dayWindow, title: "Časové okno ranního plánu", current: "\(hm(curStart))–\(hm(curEnd))",
                          proposed: "\(hm(newStart))–\(hm(newEnd))", reasons: reasons,
                          settings: ["planDayStart": after["start"]!, "planDayEnd": after["end"]!], subjects: [],
                          before: .object(before), after: .object(after))
    }
}
