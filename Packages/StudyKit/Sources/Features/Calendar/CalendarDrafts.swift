import Core
import Engine
import Foundation

// Rozpracované formuláře kalendáře: stejná pravidla a stejný tvar záznamů jako modální okna na webu
// (`BlockModal`, `ExamModal` v `PlannerModals.tsx`, `SessionModal` v `HistoryPage.tsx`).
// Čas se ve formuláři drží jako `Date` (DatePicker), do dat se zapisuje v ms jako na webu.

/// Blok plánu.
public struct PlanBlockDraft: Equatable, Sendable {
    /// „Opakovat každý týden“ – počet týdnů (1 = neopakovat).
    public static let repeatChoices = [1, 2, 4, 8, 12, 16]

    public var original: PlanBlock?
    public var subjectId: String
    public var title: String
    /// Den a čas začátku (na minuty).
    public var start: Date
    public var durationMin: Int
    public var note: String
    public var repeatWeeks = 1

    /// Nový blok začínající v `start` (na webu 50 minut).
    public init(newAt start: Int, subjectId: String = "", clock: StudyClock) {
        original = nil
        self.subjectId = subjectId
        title = ""
        self.start = minutePrecision(start, clock: clock)
        durationMin = 50
        note = ""
    }

    public init(editing block: PlanBlock, clock: StudyClock) {
        original = block
        subjectId = block.subjectId
        title = block.title
        start = minutePrecision(block.start, clock: clock)
        durationMin = block.durationMin
        note = block.note
    }

    public var canSave: Bool { !subjectId.isEmpty }

    /// Záznamy k uložení: úprava zachová ostatní pole, nový blok (případně jeden na každý týden)
    /// má pořadí klíčů jako na webu.
    public func records(clock: StudyClock) -> [PlanBlock] {
        let startMs = combine(start, clock: clock)
        let duration = max(5, durationMin)
        if var b = original {
            b.subjectId = subjectId
            b.title = title.jsTrimmed
            b.start = startMs
            b.durationMin = duration
            b.note = note.jsTrimmed
            return [b]
        }
        return (0..<max(1, repeatWeeks)).map { week in
            PlanBlock(raw: [
                "id": .string(PlanBlock.newID()), "subjectId": .string(subjectId), "title": .string(title.jsTrimmed),
                "start": .number(Double(clock.addDays(startMs, week * 7))), "durationMin": .number(Double(duration)),
                "done": false, "note": .string(note.jsTrimmed),
            ])
        }
    }
}

/// Ruční zápis nebo úprava sezení, i zápis z bloku plánu („Hotovo“).
public struct SessionDraft: Equatable, Sendable {
    public var original: Session?
    /// Blok, ze kterého se zapisuje – po uložení se odškrtne.
    public var planBlock: PlanBlock?
    public var subjectId: String
    public var topic: String
    public var start: Date
    /// Čistý čas v minutách.
    public var minutes: Int
    /// 0 = nehodnoceno, jinak 1–5.
    public var focus: Int
    public var note: String
    private let initialStart: Date
    private let initialMinutes: Int

    /// Nový ruční zápis; bez `start` jako na webu: posledních 50 minut.
    public init(newAt start: Int? = nil, now: Int, clock: StudyClock) {
        self.init(subjectId: "", topic: "", start: start ?? now - 50 * StudyClock.minute, minutes: 50, focus: 0, note: "", clock: clock)
    }

    /// Zápis z bloku plánu: předmět a téma z bloku, čas, který z bloku do teď proběhl.
    /// Vygenerovaný název bloku („Po přednášce: …“) se nehodí jako téma – zůstane aspoň v poznámce.
    public init(fromBlock block: PlanBlock, now: Int, clock: StudyClock) {
        let span = PlanMatch.loggedSpan(of: block, now: now)
        let topic = blockTopics(block.title).first ?? ""
        self.init(subjectId: block.subjectId, topic: topic, start: span.start, minutes: span.minutes, focus: 0,
                  note: topic != block.title.jsTrimmed ? block.title : "", clock: clock)
        planBlock = block
    }

    public init(editing session: Session, clock: StudyClock) {
        self.init(subjectId: session.subjectId, topic: session.topic, start: session.start,
                  minutes: Int(JS.round(Double(session.durationSec) / 60)), focus: session.focus ?? 0, note: session.note, clock: clock)
        original = session
    }

    private init(subjectId: String, topic: String, start: Int, minutes: Int, focus: Int, note: String, clock: StudyClock) {
        self.subjectId = subjectId
        self.topic = topic
        self.start = minutePrecision(start, clock: clock)
        self.minutes = minutes
        self.focus = focus
        self.note = note
        initialStart = self.start
        initialMinutes = minutes
    }

    public var isNew: Bool { original == nil }
    public var canSave: Bool { !subjectId.isEmpty && minutes > 0 }

    /// Sezení k uložení. Na rozdíl od webu úprava, která nezměnila začátek ani délku, zachová přesný
    /// začátek (se sekundami) i čistý čas – jinak by se úpravou poznámky sezení z časovače zaokrouhlilo.
    public func record(clock: StudyClock) -> Session {
        let s = original.flatMap { start == initialStart ? $0.start : nil } ?? combine(start, clock: clock)
        let durationSec = original.flatMap { minutes == initialMinutes ? $0.durationSec : nil } ?? minutes * 60
        // U sezení z časovače zůstane skutečný konec (s pauzami), pokud se nezměnil začátek.
        let end = original.map { $0.start == s ? max($0.end, s + durationSec * 1000) : s + durationSec * 1000 } ?? s + durationSec * 1000
        var out = original ?? Session(raw: ["id": .string(Session.newID()), "mode": "manual", "interruptions": 0])
        out.subjectId = subjectId
        out.topic = topic.jsTrimmed
        out.start = s
        out.end = end
        out.durationSec = durationSec
        out.focus = focus == 0 ? nil : focus
        out.note = note.jsTrimmed
        return out
    }
}

/// Zkouška: předmět, název, termín (čas je volitelný) a poznámka.
public struct ExamDraft: Equatable, Sendable {
    public var original: Exam?
    public var subjectId: String
    public var name: String
    public var day: Date
    public var hasTime: Bool
    public var time: Date
    public var note: String

    /// Nová zkouška – jako na webu za dva týdny.
    public init(newAt now: Int, clock: StudyClock) {
        original = nil
        subjectId = ""
        name = ""
        day = clock.date(clock.startOfDay(clock.addDays(now, 14)))
        hasTime = false
        time = clock.date(clock.atMinutes(clock.startOfDay(now), 9 * 60))
        note = ""
    }

    public init(editing exam: Exam, now: Int, clock: StudyClock) {
        self.init(newAt: now, clock: clock)
        original = exam
        subjectId = exam.subjectId
        name = exam.name
        let examDay = clock.parseDayKey(exam.date) ?? clock.startOfDay(now)
        day = clock.date(examDay)
        if let minutes = Self.minutes(exam.time) {
            hasTime = true
            time = clock.date(clock.atMinutes(examDay, minutes))
        }
        note = exam.note
    }

    public var canSave: Bool { !subjectId.isEmpty && !name.jsTrimmed.isEmpty }

    public func record(clock: StudyClock) -> Exam {
        var e = original ?? Exam(raw: ["id": .string(Exam.newID())])
        e.subjectId = subjectId
        e.name = name.jsTrimmed
        e.date = clock.dayKey(clock.ms(day))
        e.time = hasTime ? Format.time(clock.ms(time), clock: clock) : ""
        e.note = note.jsTrimmed
        return e
    }

    /// „HH:MM“ → minuty od půlnoci.
    static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}

/// Okamžik oříznutý na minuty – formuláře na webu (`type="time"`, `datetime-local`) sekundy nemají.
private func minutePrecision(_ t: Int, clock: StudyClock) -> Date {
    let c = clock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: clock.date(t))
    return clock.calendar.date(from: c) ?? clock.date(t)
}

/// Den a čas z formuláře → ms (`combine(date, time)` na webu: půlnoc dne + hodiny a minuty v místním čase).
private func combine(_ date: Date, clock: StudyClock) -> Int {
    let c = clock.calendar.dateComponents([.hour, .minute], from: date)
    return clock.atMinutes(clock.startOfDay(clock.ms(date)), (c.hour ?? 0) * 60 + (c.minute ?? 0))
}
