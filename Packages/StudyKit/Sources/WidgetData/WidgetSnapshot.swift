import Foundation

/// Souhrn pro widgety, který aplikace zapisuje do sdíleného kontejneru (jen odvozený výřez z dat –
/// zdrojem pravdy zůstává `data.json`). Widget z něj sám dopočítá stav pro libovolný okamžik:
/// běžící odpočet, přechod na další den, další blok plánu, dny do zkoušky – i když aplikace neběží.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = WidgetSnapshot.currentVersion
    /// Kdy aplikace souhrn sestavila (ms).
    public var generatedAt: Int
    /// Půlnoci dneška, zítřka a pozítří v místním čase (přechod dne bez aplikace, i přes změnu času).
    public var days: [Int]
    public var goalSec: Int
    /// Dnes odučeno (uložená sezení, bez právě běžícího bloku).
    public var studiedSec: Int
    public var weekSec: Int
    public var weekGoalSec: Int
    /// Odučeno po dnech týdne (Po–Ne).
    public var week: [Int]
    /// Index dneška v `week` (0 = pondělí).
    public var todayIndex: Int
    public var streak: Int
    public var subjects: [String: SubjectStyle]
    /// Bloky plánu na dnešek a zítřek podle začátku.
    public var plan: [Block]
    /// Nadcházející zkoušky podle data.
    public var exams: [ExamItem]
    public var timer: TimerInfo
    /// „Co teď?“ v okamžiku sestavení (nejvýš tři).
    public var nextUp: [NextUp]
    /// Aplikace běží – tlačítka pošlou příkaz rovnou; jinak ji otevřou odkazem.
    public var appRunning: Bool

    public init(generatedAt: Int, days: [Int], goalSec: Int, studiedSec: Int, weekSec: Int, weekGoalSec: Int, week: [Int], todayIndex: Int,
                streak: Int, subjects: [String: SubjectStyle], plan: [Block], exams: [ExamItem], timer: TimerInfo, nextUp: [NextUp],
                appRunning: Bool = true) {
        self.generatedAt = generatedAt
        self.days = days
        self.goalSec = goalSec
        self.studiedSec = studiedSec
        self.weekSec = weekSec
        self.weekGoalSec = weekGoalSec
        self.week = week
        self.todayIndex = todayIndex
        self.streak = streak
        self.subjects = subjects
        self.plan = plan
        self.exams = exams
        self.timer = timer
        self.nextUp = nextUp
        self.appRunning = appRunning
    }

    public struct SubjectStyle: Codable, Sendable, Equatable {
        public var name: String
        /// `#rrggbb`
        public var color: String

        public init(name: String, color: String) {
            self.name = name
            self.color = color
        }
    }

    public struct Block: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var subjectId: String
        public var title: String
        public var topic: String
        public var start: Int
        public var end: Int
        public var done: Bool

        public init(id: String, subjectId: String, title: String, topic: String, start: Int, end: Int, done: Bool) {
            self.id = id
            self.subjectId = subjectId
            self.title = title
            self.topic = topic
            self.start = start
            self.end = end
            self.done = done
        }
    }

    public struct ExamItem: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var subjectId: String
        public var name: String
        /// Půlnoc dne zkoušky.
        public var day: Int
        /// `HH:MM` nebo prázdné.
        public var time: String

        public init(id: String, subjectId: String, name: String, day: Int, time: String) {
            self.id = id
            self.subjectId = subjectId
            self.name = name
            self.day = day
            self.time = time
        }
    }

    public struct NextUp: Codable, Sendable, Equatable {
        public var subjectId: String
        public var title: String
        public var topic: String
        public var modeId: String
        public var minutes: Int
        public var reason: String

        public init(subjectId: String, title: String, topic: String, modeId: String, minutes: Int, reason: String) {
            self.subjectId = subjectId
            self.title = title
            self.topic = topic
            self.modeId = modeId
            self.minutes = minutes
            self.reason = reason
        }
    }

    /// Časovač jako časové značky – odpočet si widget dopočítá sám.
    public struct TimerInfo: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case idle, ready, running, paused }

        public var status: Status
        public var isWork: Bool
        public var subjectId: String
        public var topic: String
        public var modeName: String
        /// Počítá nahoru (Flowtime, stopky).
        public var countsUp: Bool
        public var segmentStart: Int?
        public var accumulated: Int
        public var phaseDurationMs: Int?
        public var planBlockId: String?

        public init(status: Status, isWork: Bool, subjectId: String, topic: String, modeName: String, countsUp: Bool,
                    segmentStart: Int?, accumulated: Int, phaseDurationMs: Int?, planBlockId: String?) {
            self.status = status
            self.isWork = isWork
            self.subjectId = subjectId
            self.topic = topic
            self.modeName = modeName
            self.countsUp = countsUp
            self.segmentStart = segmentStart
            self.accumulated = accumulated
            self.phaseDurationMs = phaseDurationMs
            self.planBlockId = planBlockId
        }

        public static let idle = TimerInfo(status: .idle, isWork: true, subjectId: "", topic: "", modeName: "", countsUp: false,
                                           segmentStart: nil, accumulated: 0, phaseDurationMs: nil, planBlockId: nil)

        public var isActive: Bool { status == .running || status == .paused }

        public func elapsed(at t: Int) -> Int {
            accumulated + (status == .running ? max(0, t - (segmentStart ?? t)) : 0)
        }

        /// Zbývá do konce fáze (`nil` = počítá nahoru).
        public func remaining(at t: Int) -> Int? {
            guard !countsUp, let phaseDurationMs else { return nil }
            return max(0, phaseDurationMs - elapsed(at: t))
        }

        /// Okamžik konce běžící fáze.
        public var phaseEnd: Int? {
            guard status == .running, !countsUp, let phaseDurationMs, let segmentStart else { return nil }
            return segmentStart + phaseDurationMs - accumulated
        }

        /// Kdy by fáze začala, kdyby běžela bez přerušení – pro živé počítání nahoru (`Text(_, style: .timer)`).
        public var virtualStart: Int? {
            guard status == .running, let segmentStart else { return nil }
            return segmentStart - accumulated
        }

        /// Podíl uplynulé fáze 0–1.
        public func progress(at t: Int) -> Double {
            guard let phaseDurationMs, phaseDurationMs > 0, !countsUp else { return 0 }
            return min(1, Double(elapsed(at: t)) / Double(phaseDurationMs))
        }
    }

    // MARK: - Odhad po stisku tlačítka

    /// Stav, který widget ukáže hned po stisku, než aplikace pošle skutečný (zpravidla do vteřiny).
    public func applying(_ action: WidgetCommand.Action, at t: Int) -> WidgetSnapshot {
        var s = self
        var timer = s.timer
        switch action {
        case .pause where timer.status == .running:
            timer.accumulated = timer.elapsed(at: t)
            timer.segmentStart = nil
            timer.status = .paused
        case .resume where timer.status == .paused:
            timer.segmentStart = t
            timer.status = .running
        case .finish where timer.isActive && timer.isWork, .stop where timer.isActive:
            if timer.isWork { s.studiedSec += timer.elapsed(at: t) / 1000 }
            timer = action == .stop ? .idle : WidgetSnapshot.TimerInfo(
                status: .ready, isWork: false, subjectId: timer.subjectId, topic: timer.topic, modeName: timer.modeName,
                countsUp: false, segmentStart: nil, accumulated: 0, phaseDurationMs: nil, planBlockId: nil
            )
        default:
            return s
        }
        s.timer = timer
        return s
    }

    // MARK: - Dopočet pro okamžik

    public func subject(_ id: String) -> SubjectStyle {
        subjects[id] ?? SubjectStyle(name: id.isEmpty ? "Bez předmětu" : "Smazaný předmět", color: "#9aa3ad")
    }
}

/// Co widget ukáže v okamžiku `at` – i hodiny nebo dny po sestavení souhrnu.
public struct WidgetMoment: Sendable, Equatable {
    public let at: Int
    /// Půlnoc dne, který se ukazuje (po půlnoci bez aplikace už zítřek).
    public let day: Int
    /// Souhrn je ze starší doby (aplikace dlouho neběžela) – dnešní čísla nemusí sedět.
    public let isStale: Bool
    public let studiedSec: Int
    public let goalSec: Int
    public let timer: WidgetSnapshot.TimerInfo
    /// Běžící fáze už podle času skončila (aplikace ji ještě nezpracovala).
    public let phaseOver: Bool
    /// Bloky dne, který se ukazuje.
    public let plan: [WidgetSnapshot.Block]
    public let current: WidgetSnapshot.Block?
    public let next: WidgetSnapshot.Block?
    public let exams: [(exam: WidgetSnapshot.ExamItem, daysLeft: Int)]
    public let week: [Int]
    public let todayIndex: Int
    public let weekSec: Int

    public init(_ s: WidgetSnapshot, at t: Int) {
        at = t
        let days = s.days.count >= 3 ? s.days : [s.generatedAt, s.generatedAt + 86_400_000, s.generatedAt + 2 * 86_400_000]
        let rolled = t >= days[1]
        let day = t >= days[2] ? days[2] : rolled ? days[1] : days[0]
        self.day = day
        let dayEnd = day == days[0] ? days[1] : day == days[1] ? days[2] : day + 86_400_000
        isStale = t >= days[2]
        timer = s.timer
        phaseOver = s.timer.phaseEnd.map { t >= $0 } ?? false
        // Běžící blok učení se do dneška započítá živě.
        let live = s.timer.status == .running && s.timer.isWork ? min(s.timer.elapsed(at: t), s.timer.phaseDurationMs ?? .max) / 1000 : 0
        studiedSec = (rolled ? 0 : s.studiedSec) + live
        goalSec = s.goalSec
        let plan = s.plan.filter { $0.start >= day && $0.start < dayEnd }
        self.plan = plan
        current = plan.first { !$0.done && $0.start <= t && $0.end > t }
        next = plan.first { !$0.done && $0.start > t }
        exams = s.exams.compactMap { e in
            let left = Int((Double(e.day - day) / 86_400_000).rounded())
            return left >= 0 ? (e, left) : nil
        }
        week = rolled && s.todayIndex == 6 ? Array(repeating: 0, count: 7) : s.week
        todayIndex = rolled ? (s.todayIndex + 1) % 7 : s.todayIndex
        weekSec = rolled && s.todayIndex == 6 ? 0 : s.weekSec
    }

    public static func == (a: WidgetMoment, b: WidgetMoment) -> Bool {
        a.at == b.at && a.day == b.day && a.studiedSec == b.studiedSec && a.timer == b.timer && a.plan == b.plan
            && a.exams.map(\.exam) == b.exams.map(\.exam) && a.exams.map(\.daysLeft) == b.exams.map(\.daysLeft) && a.phaseOver == b.phaseOver
    }

    public var fraction: Double { goalSec > 0 ? min(1, Double(studiedSec) / Double(goalSec)) : 0 }
}

/// Časová osa widgetu: okamžiky, kdy se má sám překreslit (bez aplikace a bez probouzení).
public enum WidgetTimeline {
    /// Od `now` na `hours` dopředu: začátky a konce bloků, konec fáze časovače, půlnoc, a během
    /// běžícího bloku každou minutu (kruh postupu; čísla odpočtu běží živě sama).
    public static func dates(_ s: WidgetSnapshot, from now: Int, hours: Int = 6) -> [Int] {
        let limit = now + hours * 3_600_000
        var out: Set<Int> = [now]
        for b in s.plan {
            for t in [b.start, b.end] where t > now && t < limit { out.insert(t) }
        }
        for d in s.days where d > now && d < limit { out.insert(d) }
        if let end = s.timer.phaseEnd, end > now {
            var t = now + 60_000 - (now % 60_000)
            while t < min(end, limit) {
                out.insert(t)
                t += 60_000
            }
            if end < limit { out.insert(end) }
        } else if s.timer.status == .running, s.timer.isWork {
            // Počítá nahoru – dnešní součet roste: po pěti minutách stačí.
            var t = now + 300_000 - (now % 300_000)
            while t < limit {
                out.insert(t)
                t += 300_000
            }
        }
        return out.sorted()
    }

    /// Kdy si widget má říct o novou časovou osu (aplikace stejně překreslí widgety po každé změně).
    public static func refresh(_ s: WidgetSnapshot, from now: Int, hours: Int = 6) -> Int {
        let next = s.days.first { $0 > now } ?? now + hours * 3_600_000
        return min(now + hours * 3_600_000, next + 1000)
    }
}
