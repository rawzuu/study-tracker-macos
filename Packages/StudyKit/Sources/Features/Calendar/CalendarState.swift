import Core
import Engine
import Foundation

// Stav stránky Kalendář (`PlannerPage` a `MonthView` na webu): co se v týdnu a měsíci ukáže.
// Čisté funkce dokument → zobrazení, testované bez UI.

/// Které položky kalendář ukazuje (`Layer` na webu).
public enum CalendarLayer: String, CaseIterable, Sendable {
    case all, done, plan

    public var title: String {
        switch self {
        case .all: "Vše"
        case .done: "Odučeno"
        case .plan: "Plán"
        }
    }
}

/// Zkouška v záhlaví dne nebo v buňce měsíce.
public struct ExamPill: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let subject: SubjectInfo
}

/// Odučený čas jednoho předmětu (barevný proužek dne, legenda).
public struct SubjectTime: Identifiable, Hashable, Sendable {
    public let subject: SubjectInfo
    public let sec: Int
    public var id: String { subject.id }
}

// MARK: - Týden

public struct CalendarWeekState: Sendable {
    public struct Day: Identifiable, Sendable {
        public let start: Int
        public let weekday: String
        public let number: Int
        public let isToday: Bool
        /// „2 h 15 min“, `nil` = nic odučeno
        public let total: String?
        /// Odučeno po předmětech v pořadí, v jakém se v datech objevily.
        public let mix: [SubjectTime]
        public let exams: [ExamPill]
        /// Položky dne (už rozdělené přes půlnoc) se sloupci.
        public let items: [Item]
        public var id: Int { start }
    }

    public struct Item: Identifiable, Sendable {
        public let item: CalendarItem
        public let lane: CalendarLayout.Lane
        public let subject: SubjectInfo
        /// Blok plánu je hotový.
        public let done: Bool
        /// Druhý řádek: téma, „plán“, délka, „právě teď“ nebo místnost.
        public let detail: String
        /// „9:00–10:30“ (celá položka, i když je rozdělená přes půlnoc)
        public let timeLabel: String
        public let tooltip: String
        public var id: String { item.id }
    }

    public let weekStart: Int
    /// „19. října – 25. října“
    public let title: String
    public let isCurrentWeek: Bool
    public let days: [Day]
    public let firstHour: Int
    public let studied: String
    public let planned: String
    /// Odučeno tento týden po předmětech, od nejvíc.
    public let legend: [SubjectTime]
    public let hasLectures: Bool
    /// V týdnu jsou události z ostatních kalendářů (obsazený čas).
    public let hasExternal: Bool

    /// - Parameters:
    ///   - live: běžící blok učení na časovači (kreslí se, dokud běží)
    ///   - external: události z ostatních kalendářů v Apple Kalendáři (obsazený čas)
    public init(document doc: AppDocument, weekStart: Int, layer: CalendarLayer, live: TimerState?, external: [ExternalBusy] = [],
                now: Int, clock: StudyClock) {
        let subjects = SubjectLookup(doc)
        let weekEnd = clock.addDays(weekStart, 7)
        let blocks = doc.alive(PlanBlock.self).filter { $0.start >= weekStart && $0.start < weekEnd }
        let sessions = Stats.inRange(doc.alive(Session.self), from: weekStart, to: weekEnd)
        let exams = doc.alive(Exam.self)
        self.weekStart = weekStart
        title = "\(Format.date(weekStart, .dayMonth, clock: clock)) – \(Format.date(clock.addDays(weekStart, 6), .dayMonth, clock: clock))"
        isCurrentWeek = weekStart == clock.startOfWeek(now)

        let lectures = layer == .done ? [] : Timetables.lectures(doc, from: weekStart, to: weekEnd)
        var items: [CalendarItem] = lectures.map {
            CalendarItem(id: "l-\($0.timetableId)-\($0.event.key)", source: .lecture(timetableId: $0.timetableId, key: $0.event.key),
                         subjectId: "", start: $0.event.start, end: $0.event.end, title: $0.event.title)
        }
        let busy = layer == .done ? [] : external.filter { $0.end > weekStart && $0.start < weekEnd }
        items += busy.map { CalendarItem(id: "x-\($0.id)", source: .external(id: $0.id), subjectId: "", start: $0.start, end: $0.end, title: $0.title) }
        if layer != .done {
            for b in blocks {
                // Hotový blok se zapsaným časem ve „Vše“ nahradí plné sezení – jinak by tam byl dvakrát.
                if layer == .all && b.done && PlanMatch.hasSession(sessions, for: b) { continue }
                items.append(CalendarItem(id: "p-\(b.id)", source: .block(id: b.id), subjectId: b.subjectId, start: b.start,
                                          end: b.start + b.durationMin * StudyClock.minute, title: b.title))
            }
        }
        if layer != .plan {
            items += sessions.map { CalendarItem(id: "s-\($0.id)", source: .session(id: $0.id), subjectId: $0.subjectId, start: $0.start, end: $0.end, title: $0.topic) }
            if let live, live.isStudying, let ws = live.workStartedAt, ws >= weekStart && ws < weekEnd {
                items.append(CalendarItem(id: "live", source: .live, subjectId: live.subjectId, start: ws, end: max(now, ws + 10 * StudyClock.minute), title: live.topic))
            }
        }
        items = items.flatMap { CalendarLayout.splitAtMidnight($0, clock: clock) }
        firstHour = CalendarLayout.firstHour(items, clock: clock)
        hasLectures = !lectures.isEmpty
        hasExternal = !busy.isEmpty
        let locations = Dictionary(lectures.map { ("\($0.timetableId)|\($0.event.key)", $0.event.location) }, uniquingKeysWith: { a, _ in a })

        let calendarOf = Dictionary(busy.map { ($0.id, $0.calendarTitle) }, uniquingKeysWith: { a, _ in a })
        let blockById = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sessionById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let today = clock.startOfDay(now)
        days = (0..<7).map { i in
            let day = clock.addDays(weekStart, i)
            let daySessions = sessions.filter { clock.startOfDay($0.start) == day }
            let sec = Stats.totalSec(daySessions)
            let dayItems = items.filter { clock.startOfDay($0.start) == day }
            let lanes = CalendarLayout.lanes(dayItems)
            return Day(
                start: day,
                weekday: Format.weekdaysShort[i],
                number: clock.calendar.component(.day, from: clock.date(day)),
                isToday: day == today,
                total: sec > 0 ? Format.duration(sec) : nil,
                mix: orderedTimes(daySessions, subjects),
                exams: exams.filter { $0.date == clock.dayKey(day) }.map { ExamPill(id: $0.id, name: $0.name, subject: subjects[$0.subjectId]) },
                items: dayItems.map { it in
                    Self.item(it, lane: lanes[it.id]!, subjects: subjects, block: blockById, session: sessionById, locations: locations,
                              calendars: calendarOf, clock: clock)
                }
            )
        }

        studied = Format.duration(Stats.totalSec(sessions))
        planned = Format.duration(blocks.reduce(0) { $0 + $1.durationMin * 60 })
        legend = orderedTimes(sessions, subjects).sorted { $0.sec > $1.sec }
    }

    private static func item(_ it: CalendarItem, lane: CalendarLayout.Lane, subjects: SubjectLookup, block: [String: PlanBlock],
                             session: [String: Session], locations: [String: String], calendars: [String: String], clock: StudyClock) -> Item {
        let subject = subjects[it.subjectId]
        let time = "\(Format.time(it.fullStart, clock: clock))–\(Format.time(it.fullEnd, clock: clock))"
        switch it.source {
        case .block(let id):
            return Item(item: it, lane: lane, subject: subject, done: block[id]?.done ?? false, detail: it.title.isEmpty ? "plán" : it.title,
                        timeLabel: time, tooltip: "Plán: \(subject.name) \(it.title) \(time)")
        case .session(let id):
            let duration = Format.duration(session[id]?.durationSec ?? 0)
            return Item(item: it, lane: lane, subject: subject, done: false, detail: it.title.isEmpty ? duration : it.title, timeLabel: time,
                        tooltip: "Odučeno: \(subject.name)\(it.title.isEmpty ? "" : " – \(it.title)") · \(time) · \(duration)")
        case .live:
            return Item(item: it, lane: lane, subject: subject, done: false, detail: "právě teď", timeLabel: time,
                        tooltip: "Právě probíhá: \(subject.name)\(it.title.isEmpty ? "" : " – \(it.title)") · \(time)")
        case .lecture(let timetableId, let key):
            let location = locations["\(timetableId)|\(key)"] ?? ""
            return Item(item: it, lane: lane, subject: subject, done: false, detail: location.isEmpty ? "výuka" : location, timeLabel: time,
                        tooltip: "Výuka: \(it.title)\(location.isEmpty ? "" : " · \(location)") · \(time)")
        case .external(let id):
            let calendar = calendars[id] ?? "Kalendář"
            return Item(item: it, lane: lane, subject: subject, done: false, detail: calendar, timeLabel: time,
                        tooltip: "Obsazeno (\(calendar)): \(it.title) · \(time)")
        }
    }
}

// MARK: - Měsíc

public struct CalendarMonthState: Sendable {
    public struct Cell: Identifiable, Sendable {
        public struct Plan: Identifiable, Hashable, Sendable {
            public let id: String
            public let time: String
            public let subject: SubjectInfo
            public let done: Bool
        }

        public let day: Int
        public let number: Int
        public let inMonth: Bool
        public let isToday: Bool
        public let total: String?
        /// Šířka proužku odučeného času (podíl nejdelšího dne, aspoň 8 %).
        public let mixWidth: Double
        /// Odučeno po předmětech, od nejvíc.
        public let subjects: [SubjectTime]
        public let exams: [ExamPill]
        public let plans: [Plan]
        public var id: Int { day }
    }

    /// „říjen 2026“
    public let title: String
    public let isCurrentMonth: Bool
    public let cells: [Cell]

    public init(document doc: AppDocument, monthStart: Int, layer: CalendarLayer, now: Int, clock: StudyClock) {
        let subjects = SubjectLookup(doc)
        let gridStart = clock.startOfWeek(monthStart)
        let month = clock.calendar.component(.month, from: clock.date(monthStart))
        let monthEnd = Self.shift(monthStart, by: 1, clock: clock)
        // Jako na webu: −0,01 vyrovná hodinu navíc nebo méně v měsíci se změnou času.
        let weeks = Int((Double(monthEnd - gridStart) / Double(7 * StudyClock.day) - 0.01).rounded(.up))
        let today = clock.startOfDay(now)
        title = Format.date(monthStart, .monthYear, clock: clock)
        isCurrentMonth = monthStart == clock.startOfMonth(now)

        let sessionsByDay = Dictionary(grouping: doc.alive(Session.self)) { clock.dayKey($0.start) }
        let blocksByDay = Dictionary(grouping: doc.alive(PlanBlock.self)) { clock.dayKey($0.start) }
        let examsByDay = Dictionary(grouping: doc.alive(Exam.self), by: \.date)
        let days = (0..<weeks * 7).map { clock.addDays(gridStart, $0) }
        let totals = days.map { Stats.totalSec(sessionsByDay[clock.dayKey($0)] ?? []) }
        let maxDay = max(3600, totals.max() ?? 0)

        cells = days.enumerated().map { i, day in
            let key = clock.dayKey(day)
            let sessions = layer == .plan ? [] : sessionsByDay[key] ?? []
            let total = layer == .plan ? 0 : totals[i]
            let blocks = layer == .done ? [] : (blocksByDay[key] ?? []).sorted { $0.start < $1.start }
            return Cell(
                day: day,
                number: clock.calendar.component(.day, from: clock.date(day)),
                inMonth: clock.calendar.component(.month, from: clock.date(day)) == month,
                isToday: day == today,
                total: total > 0 ? Format.duration(total) : nil,
                mixWidth: max(0.08, Double(total) / Double(maxDay)),
                subjects: orderedTimes(sessions, subjects).sorted { $0.sec > $1.sec },
                exams: (examsByDay[key] ?? []).map { ExamPill(id: $0.id, name: $0.name, subject: subjects[$0.subjectId]) },
                plans: blocks.filter { !(layer == .all && $0.done) }.prefix(3).map {
                    Cell.Plan(id: $0.id, time: Format.time($0.start, clock: clock), subject: subjects[$0.subjectId], done: $0.done)
                }
            )
        }
    }

    /// První den měsíce o `n` měsíců dál (`shiftMonth` na webu).
    public static func shift(_ monthStart: Int, by n: Int, clock: StudyClock) -> Int {
        var c = clock.calendar.dateComponents([.year, .month], from: clock.date(monthStart))
        c.month = (c.month ?? 1) + n
        c.day = 1
        return clock.calendar.date(from: c).map(clock.ms) ?? monthStart
    }
}

// MARK: - Plán vs. realita a zkoušky

public struct PlanVsRealityRow: Identifiable, Hashable, Sendable {
    public let subject: SubjectInfo
    public let studiedSec: Int
    public let plannedSec: Int
    public let goalSec: Int
    public var id: String { subject.id }

    /// Odučeno vůči většímu z plánu a týdenního cíle; bez plánu i cíle je proužek plný, pokud se učilo.
    public var fraction: Double {
        let target = max(plannedSec, goalSec)
        return target > 0 ? Double(studiedSec) / Double(target) : studiedSec > 0 ? 1 : 0
    }

    /// „2 h odučeno · plán 3 h · cíl 5 h“ – odučený čas zvlášť, aby šel zvýraznit.
    public var detail: String {
        "odučeno · plán \(Format.duration(plannedSec))" + (goalSec > 0 ? " · cíl \(Format.duration(goalSec))" : "")
    }

    /// Předměty, které mají v týdnu plán, odučený čas nebo týdenní cíl.
    public static func rows(document doc: AppDocument, weekStart: Int, clock: StudyClock) -> [PlanVsRealityRow] {
        let weekEnd = clock.addDays(weekStart, 7)
        let studied = Stats.bySubject(Stats.inRange(doc.alive(Session.self), from: weekStart, to: weekEnd))
        let planned = doc.alive(PlanBlock.self).filter { $0.start >= weekStart && $0.start < weekEnd }
            .reduce(into: [String: Int]()) { $0[$1.subjectId, default: 0] += $1.durationMin * 60 }
        return doc.alive(Subject.self)
            .filter { planned[$0.id] != nil || studied[$0.id] != nil || ($0.weeklyGoalMin > 0 && !$0.archived) }
            .map { PlanVsRealityRow(subject: SubjectInfo(id: $0.id, name: $0.name, color: $0.color), studiedSec: studied[$0.id] ?? 0,
                                    plannedSec: planned[$0.id] ?? 0, goalSec: $0.weeklyGoalMin * 60) }
    }
}

public struct UpcomingExamRow: Identifiable, Hashable, Sendable {
    public enum Tone: Sendable { case soon, near, later }

    public let id: String
    public let name: String
    public let subject: SubjectInfo
    /// „2. listopadu 8:30“
    public let when: String
    /// „dnes“, „za 3 dny“
    public let countdown: String
    public let tone: Tone

    public static func rows(document doc: AppDocument, now: Int, clock: StudyClock) -> [UpcomingExamRow] {
        let subjects = SubjectLookup(doc)
        return ExamCountdown.upcoming(doc, now: now, clock: clock).compactMap { e in
            guard let days = ExamCountdown.daysLeft(e, now: now, clock: clock), let day = clock.parseDayKey(e.date) else { return nil }
            return UpcomingExamRow(
                id: e.id, name: e.name, subject: subjects[e.subjectId],
                when: Format.date(day, .dayMonth, clock: clock) + (e.time.isEmpty ? "" : " \(e.time)"),
                countdown: ExamCountdown.label(daysLeft: days),
                tone: days <= 3 ? .soon : days <= 10 ? .near : .later
            )
        }
    }
}

/// Odučený čas po předmětech v pořadí prvního výskytu (jako `Map` na webu).
private func orderedTimes(_ sessions: [Session], _ subjects: SubjectLookup) -> [SubjectTime] {
    var order: [String] = []
    var sec: [String: Int] = [:]
    for s in sessions {
        if sec[s.subjectId] == nil { order.append(s.subjectId) }
        sec[s.subjectId, default: 0] += s.durationSec
    }
    return order.map { SubjectTime(subject: subjects[$0], sec: sec[$0]!) }
}
