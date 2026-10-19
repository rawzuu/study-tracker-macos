import Core
import Engine
import Foundation

/// Stavy pohledů: čisté funkce dokument → co se má zobrazit. Pohledy jen kreslí, logika je
/// tady a dá se testovat bez UI (MVVM).

public struct SubjectInfo: Hashable, Sendable {
    public let id: String
    public let name: String
    public let color: String

    static let deleted = SubjectInfo(id: "", name: "Smazaný předmět", color: "#837d73")
}

struct SubjectLookup {
    private let byId: [String: SubjectInfo]

    init(_ doc: AppDocument) {
        var map: [String: SubjectInfo] = [:]
        // Jako `data.subjects.find(...)` na webu: první záznam s daným id, i smazaný.
        for s in doc.records(Subject.self) where map[s.id] == nil {
            map[s.id] = SubjectInfo(id: s.id, name: s.name, color: s.color)
        }
        byId = map
    }

    subscript(id: String) -> SubjectInfo { byId[id] ?? .deleted }
}

/// Řádek sezení (Historie, Přehled).
public struct SessionRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let subject: SubjectInfo
    public let start: Int
    /// „09:05–09:50“
    public let timeRange: String
    /// „dnes 09:05“ / „15. 10. 09:05“
    public let when: String
    public let topic: String
    public let mode: String
    /// „Téma · Pomodoro · 2× vyrušení · poznámka“
    public let detail: String
    /// Totéž bez tématu: „Pomodoro · 2× vyrušení · poznámka“ (téma je v názvu řádku).
    public let extra: String
    public let recall: String?
    public let focus: Int?
    public let duration: String

    init(_ s: Session, subjects: SubjectLookup, presets: [String: String], now: Int, clock: StudyClock) {
        id = s.id
        subject = subjects[s.subjectId]
        start = s.start
        timeRange = "\(Format.time(s.start, clock: clock))–\(Format.time(s.end, clock: clock))"
        let c = clock.calendar.dateComponents([.day, .month], from: clock.date(s.start))
        let day = clock.dayKey(s.start) == clock.dayKey(now) ? "dnes" : "\(c.day ?? 0). \(c.month ?? 0)."
        when = "\(day) \(Format.time(s.start, clock: clock))"
        topic = s.topic
        mode = Format.modeName(s.mode, presets: presets)
        let rest = [mode, s.interruptions > 0 ? "\(s.interruptions)× vyrušení" : "", s.note].filter { !$0.isEmpty }
        detail = ([s.topic].filter { !$0.isEmpty } + rest).joined(separator: " · ")
        extra = rest.joined(separator: " · ")
        recall = s.recall.flatMap { $0.isEmpty ? nil : $0 }
        focus = s.focus.flatMap { $0 == 0 ? nil : $0 }
        duration = Format.duration(s.durationSec)
    }
}

extension AppDocument {
    var presetNames: [String: String] {
        Dictionary(alive(TimerPreset.self).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Přehled

public struct DashboardState: Sendable {
    public struct DayBar: Hashable, Sendable {
        public let label: String
        public let sec: Int
        public let isToday: Bool
    }

    public struct SubjectProgress: Identifiable, Hashable, Sendable {
        public let subject: SubjectInfo
        public let sec: Int
        public let goalSec: Int
        public var id: String { subject.id }
        public var fraction: Double { goalSec > 0 ? Double(sec) / Double(goalSec) : 0 }
    }

    public struct PlanRow: Identifiable, Hashable, Sendable {
        public let id: String
        public let time: String
        public let subject: SubjectInfo
        public let title: String
        public let durationMin: Int
        public let done: Bool
        /// Téma pro časovač z názvu bloku („Opakování: Derivace, …“ → Derivace).
        public let topic: String
    }

    public struct ExamRow: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let subject: SubjectInfo
        public let daysLeft: Int
        public let day: String
    }

    public let title: String
    public let isoWeek: Int
    /// Záměr z reflexe minulého týdne („záměr: …“ v podtitulku), pokud reflexe není skrytá.
    public let intention: String?
    public let todaySec: Int
    public let goalSec: Int
    public let weekSec: Int
    public let weekGoalSec: Int
    public let focus7: Double?
    public let streak: (current: Int, best: Int)
    /// Změna proti minulému týdnu do stejného okamžiku (0,12 = +12 %).
    public let weekDelta: Double?
    public let weekDays: [DayBar]
    public let weekRows: [SubjectProgress]
    public let todayPlan: [PlanRow]
    public let exams: [ExamRow]
    public let recent: [SessionRow]
    /// Žádné předměty ani sezení – nová instalace bez připojených dat.
    public let isEmpty: Bool

    public init(document doc: AppDocument, now: Int, clock: StudyClock) {
        let subjects = SubjectLookup(doc)
        let sessions = doc.alive(Session.self)
        let activeSubjects = doc.alive(Subject.self).filter { !$0.archived }
        let settings = doc.settings
        let today = clock.startOfDay(now)
        let week = clock.startOfWeek(now)

        title = Format.capitalized(Format.date(now, .weekdayDayMonth, clock: clock))
        isoWeek = clock.isoWeek(now)
        let lastWeekKey = clock.dayKey(clock.addDays(clock.startOfWeek(now), -7))
        intention = settings.hiddenPages.contains("reflexe") ? nil
            : doc.records(Reflection.self).first { !$0.isDeleted && $0.weekStart == lastWeekKey && !$0.focusNext.isEmpty }?.focusNext
        todaySec = Stats.totalSec(Stats.inRange(sessions, from: today, to: now + 1))
        let weekSessions = Stats.inRange(sessions, from: week, to: now + 1)
        weekSec = Stats.totalSec(weekSessions)
        let lastWeekSec = Stats.totalSec(Stats.inRange(sessions, from: clock.addDays(week, -7), to: now - 7 * StudyClock.day))
        weekDelta = lastWeekSec > 0 ? Double(weekSec - lastWeekSec) / Double(lastWeekSec) : nil
        streak = Stats.streaks(sessions, restDays: settings.streakRestDays, minMin: settings.streakMinMin, now: now, clock: clock)
        focus7 = Stats.avgFocus(Stats.inRange(sessions, from: clock.addDays(today, -6), to: now + 1))
        goalSec = settings.dailyGoalMin * 60
        weekGoalSec = activeSubjects.reduce(0) { $0 + $1.weeklyGoalMin * 60 }

        weekDays = Format.weekdaysShort.enumerated().map { i, label in
            let from = clock.addDays(week, i)
            return DayBar(label: label, sec: Stats.totalSec(Stats.inRange(sessions, from: from, to: clock.addDays(week, i + 1))), isToday: from == today)
        }
        let bySubject = Stats.bySubject(weekSessions)
        // Předměty s cílem (v pořadí z Předmětů), pak ostatní, na kterých se tento týden pracovalo.
        let rows = activeSubjects
            .filter { $0.weeklyGoalMin > 0 || bySubject[$0.id, default: 0] > 0 }
            .map { SubjectProgress(subject: subjects[$0.id], sec: bySubject[$0.id, default: 0], goalSec: $0.weeklyGoalMin * 60) }
        weekRows = rows.filter { $0.goalSec > 0 } + rows.filter { $0.goalSec == 0 }

        todayPlan = doc.alive(PlanBlock.self)
            .filter { clock.startOfDay($0.start) == today }
            .sorted { $0.start < $1.start }
            .map {
                PlanRow(id: $0.id, time: Format.time($0.start, clock: clock), subject: subjects[$0.subjectId], title: $0.title,
                        durationMin: $0.durationMin, done: $0.done, topic: blockTopics($0.title).first ?? "")
            }

        exams = doc.alive(Exam.self)
            .compactMap { e in clock.parseDayKey(e.date).map { (e, $0) } }
            .filter { $0.1 >= today }
            .sorted { $0.0.date < $1.0.date }
            .prefix(5)
            .map { e, day in
                ExamRow(id: e.id, name: e.name, subject: subjects[e.subjectId], daysLeft: Int((Double(day - today) / Double(StudyClock.day)).rounded()), day: Format.date(day, .shortWeekdayDayNumericMonth, clock: clock))
            }

        let presets = doc.presetNames
        recent = sessions.sorted { $0.end > $1.end }.prefix(8).map { SessionRow($0, subjects: subjects, presets: presets, now: now, clock: clock) }
        isEmpty = sessions.isEmpty && doc.alive(Subject.self).isEmpty
    }
}

// MARK: - Historie

public struct HistoryState: Sendable {
    public struct DayGroup: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let total: String
        public let rows: [SessionRow]
    }

    public let groups: [DayGroup]
    public let subjects: [SubjectInfo]

    /// Sezení od nejnovějšího, po dnech; `subjectId` = filtr (`nil` = vše).
    public init(document doc: AppDocument, subjectId: String?, now: Int, clock: StudyClock) {
        let lookup = SubjectLookup(doc)
        let presets = doc.presetNames
        let list = doc.alive(Session.self)
            .filter { subjectId == nil || $0.subjectId == subjectId }
            .sorted { $0.start > $1.start }
        var order: [String] = []
        var byDay: [String: [Session]] = [:]
        for s in list {
            let key = clock.dayKey(s.start)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(s)
        }
        groups = order.map { key in
            let sessions = byDay[key]!
            return DayGroup(
                id: key,
                title: Format.capitalized(Format.dayLabel(sessions[0].start, now: now, clock: clock)),
                total: Format.duration(Stats.totalSec(sessions)),
                rows: sessions.map { SessionRow($0, subjects: lookup, presets: presets, now: now, clock: clock) }
            )
        }
        subjects = doc.alive(Subject.self).map { SubjectInfo(id: $0.id, name: $0.name, color: $0.color) }
    }
}

// MARK: - Předměty

public struct SubjectsState: Sendable {
    public struct Row: Identifiable, Hashable, Sendable {
        public let subject: SubjectInfo
        /// „Celkem 12 h 30 min · cíl 6 h týdně“
        public let summary: String
        public let weekSec: Int
        public let goalSec: Int
        public var id: String { subject.id }
        public var fraction: Double { goalSec > 0 ? Double(weekSec) / Double(goalSec) : 0 }
    }

    public let active: [Row]
    public let archived: [Row]

    public init(document doc: AppDocument, now: Int, clock: StudyClock) {
        let sessions = doc.alive(Session.self)
        let totals = Stats.bySubject(sessions)
        let week = Stats.bySubject(Stats.inRange(sessions, from: clock.startOfWeek(now), to: now + 1))
        func row(_ s: Subject) -> Row {
            var summary = "Celkem \(Format.duration(totals[s.id, default: 0]))"
            if s.weeklyGoalMin > 0 { summary += " · cíl \(Format.duration(s.weeklyGoalMin * 60)) týdně" }
            return Row(subject: SubjectInfo(id: s.id, name: s.name, color: s.color), summary: summary, weekSec: week[s.id, default: 0], goalSec: s.weeklyGoalMin * 60)
        }
        let all = doc.alive(Subject.self)
        active = all.filter { !$0.archived }.map(row)
        archived = all.filter(\.archived).map(row)
    }
}
