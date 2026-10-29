import Core

/// Pondělní souhrn minulého týdne do oznámení (jen Mac): kolik ses učil proti cíli, nejlepší den,
/// změna proti týdnu předtím a nejbližší zkouška.
public enum WeeklySummary {
    public struct Text: Sendable, Equatable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Týden (jeho začátek), za který se souhrn posílá: ten před aktuálním.
    public static func week(now: Int, clock: StudyClock) -> Int {
        clock.addDays(clock.startOfWeek(now), -7)
    }

    /// `nil` = není o čem psát (minulý týden bez učení, bez cílů a bez blížící se zkoušky).
    public static func make(_ doc: AppDocument, now: Int, clock: StudyClock) -> Text? {
        let from = week(now: now, clock: clock)
        let to = clock.startOfWeek(now)
        let sessions = doc.alive(Session.self)
        let total = Stats.totalSec(Stats.inRange(sessions, from: from, to: to))
        let before = Stats.totalSec(Stats.inRange(sessions, from: clock.addDays(from, -7), to: from))
        let goal = doc.alive(Subject.self).filter { !$0.archived }.reduce(0) { $0 + $1.weeklyGoalMin * 60 }
        let exam = ExamCountdown.upcoming(doc, now: now, clock: clock).lazy
            .compactMap { e in ExamCountdown.daysLeft(e, now: now, clock: clock).map { (e, $0) } }
            .first { $0.1 <= 14 }
        guard total > 0 || goal > 0 || exam != nil else { return nil }

        var parts: [String] = []
        if goal > 0 {
            parts.append("\(Int((Double(total) / Double(goal) * 100).rounded())) % týdenního cíle (\(Format.duration(goal)))")
        }
        if let best = bestDay(sessions, from: from, clock: clock) {
            parts.append("nejvíc \(onWeekday[best.index]) (\(Format.duration(best.sec)))")
        }
        if before > 0, total > 0 {
            let change = Int((Double(total - before) / Double(before) * 100).rounded())
            parts.append(change == 0 ? "stejně jako týden předtím" : "\(change > 0 ? "+" : "−")\(abs(change)) % proti týdnu předtím")
        }
        var body = parts.joined(separator: " · ")
        if let (e, days) = exam {
            let next = "Blíží se: \(e.name) \(ExamCountdown.label(daysLeft: days))."
            body = body.isEmpty ? next : body + ". " + next
        } else if !body.isEmpty {
            body += "."
        }
        let title = total > 0 ? "Minulý týden: \(Format.duration(total))" : "Minulý týden bez učení"
        return Text(title: title, body: body)
    }

    /// Den týdne s nejvíc učením (při shodě dřívější).
    static func bestDay(_ sessions: [Session], from: Int, clock: StudyClock) -> (index: Int, sec: Int)? {
        var best: (index: Int, sec: Int)?
        for i in 0..<7 {
            let sec = Stats.totalSec(Stats.inRange(sessions, from: clock.addDays(from, i), to: clock.addDays(from, i + 1)))
            if sec > 0, sec > (best?.sec ?? 0) { best = (i, sec) }
        }
        return best
    }

    /// „v pondělí“ … „v neděli“
    static let onWeekday = ["v pondělí", "v úterý", "ve středu", "ve čtvrtek", "v pátek", "v sobotu", "v neděli"]
}
