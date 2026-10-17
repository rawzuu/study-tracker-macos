import Core
import Engine
import Foundation
import Testing
@testable import Features

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let min = StudyClock.minute

private func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi, second: s))!)
}

@Suite("Formuláře kalendáře")
struct CalendarDraftTests {
    @Test("Nový blok: klíče jako na webu, opakování drží čas i přes změnu času")
    func newBlock() {
        var draft = PlanBlockDraft(newAt: at(10, 19, 9, 0, 42), clock: clock)
        #expect(clock.ms(draft.start) == at(10, 19, 9)) // formulář sekundy nemá
        draft.subjectId = "a"
        draft.title = "  Kapitola 5 \n"
        draft.repeatWeeks = 2
        let blocks = draft.records(clock: clock)
        #expect(blocks.count == 2)
        #expect(Array(blocks[0].raw.keys) == ["id", "subjectId", "title", "start", "durationMin", "done", "note"])
        #expect(blocks[0].title == "Kapitola 5" && blocks[0].durationMin == 50 && !blocks[0].done)
        // 25. 10. končí letní čas – blok o týden později je pořád v 9:00
        #expect(blocks.map(\.start) == [at(10, 19, 9), at(10, 26, 9)])
        #expect(blocks[0].id != blocks[1].id)
    }

    @Test("Úprava bloku zachová neznámá pole i jejich pořadí")
    func editBlock() {
        let original = PlanBlock(raw: [
            "id": "b", "subjectId": "a", "title": "Staré", "start": .number(Double(at(10, 19, 9))), "durationMin": 45,
            "done": false, "examId": "e", "note": "", "zWeb": 1, "createdAt": 1, "updatedAt": 2,
        ])
        var draft = PlanBlockDraft(editing: original, clock: clock)
        draft.title = "Nové"
        draft.durationMin = 2 // pod minimum
        draft.repeatWeeks = 4 // úprava se neopakuje
        let blocks = draft.records(clock: clock)
        #expect(blocks.count == 1)
        #expect(Array(blocks[0].raw.keys) == Array(original.raw.keys))
        #expect(blocks[0].title == "Nové" && blocks[0].durationMin == 5 && blocks[0].examId == "e")
    }

    @Test("Ruční zápis: klíče jako na webu, soustředění jen když je vyplněné")
    func manualSession() {
        let now = at(10, 19, 12)
        var draft = SessionDraft(now: now, clock: clock)
        #expect(clock.ms(draft.start) == now - 50 * min && draft.minutes == 50)
        draft.subjectId = "a"
        draft.topic = " Derivace "
        var s = draft.record(clock: clock)
        #expect(Array(s.raw.keys) == ["id", "mode", "interruptions", "subjectId", "topic", "start", "end", "durationSec", "note"])
        #expect(s.mode == "manual" && s.topic == "Derivace" && s.end - s.start == 50 * min && s.durationSec == 3000)
        draft.focus = 4
        s = draft.record(clock: clock)
        #expect(Array(s.raw.keys).suffix(2) == ["focus", "note"] && s.focus == 4)
    }

    @Test("Zápis z bloku: téma z názvu, vygenerovaný název do poznámky")
    func fromBlock() {
        func block(_ title: String) -> PlanBlock {
            PlanBlock(raw: ["id": "b", "subjectId": "a", "title": .string(title), "start": .number(Double(at(10, 19, 9))), "durationMin": 50])
        }
        let now = at(10, 19, 9, 30)
        let review = SessionDraft(fromBlock: block("Opakování: Derivace, Limity"), now: now, clock: clock)
        #expect(review.topic == "Derivace" && review.note == "Opakování: Derivace, Limity")
        #expect(clock.ms(review.start) == at(10, 19, 9) && review.minutes == 30 && review.planBlock?.id == "b")
        let plain = SessionDraft(fromBlock: block("Kapitola 5"), now: now, clock: clock)
        #expect(plain.topic == "Kapitola 5" && plain.note.isEmpty)
        let lecture = SessionDraft(fromBlock: block("Po přednášce: Anatomie"), now: now, clock: clock)
        #expect(lecture.topic.isEmpty && lecture.note == "Po přednášce: Anatomie")
    }

    @Test("Úprava sezení z časovače bez změny času zachová přesný začátek, čistý čas i konec s pauzami")
    func editTimerSession() {
        let start = at(10, 19, 9, 0, 37)
        let original = Session(raw: [
            "id": "timer-1", "subjectId": "a", "topic": "", "start": .number(Double(start)), "end": .number(Double(start + 70 * min)),
            "durationSec": 3001, "mode": "pomodoro", "interruptions": 1, "note": "", "createdAt": 1, "updatedAt": 2,
        ])
        var draft = SessionDraft(editing: original, clock: clock)
        #expect(draft.minutes == 50)
        draft.note = "Šlo to"
        var s = draft.record(clock: clock)
        #expect(s.start == start && s.durationSec == 3001 && s.end == start + 70 * min && s.note == "Šlo to")
        #expect(Array(s.raw.keys) == Array(original.raw.keys))
        // Jiná délka: čistý čas z formuláře, konec zůstane (s pauzami byl delší)
        draft.minutes = 60
        s = draft.record(clock: clock)
        #expect(s.start == start && s.durationSec == 3600 && s.end == start + 70 * min)
        // Jiný začátek: jako na webu se konec dopočítá z čistého času
        draft.start = clock.date(at(10, 19, 10))
        s = draft.record(clock: clock)
        #expect(s.start == at(10, 19, 10) && s.end == at(10, 19, 11))
    }

    @Test("Zkouška: klíče jako na webu, čas je volitelný")
    func exam() {
        let now = at(10, 19, 12)
        var draft = ExamDraft(newAt: now, clock: clock)
        #expect(clock.dayKey(clock.ms(draft.day)) == "2026-11-02" && !draft.canSave)
        draft.subjectId = "a"
        draft.name = " Zápočet "
        #expect(draft.canSave)
        var e = draft.record(clock: clock)
        #expect(Array(e.raw.keys) == ["id", "subjectId", "name", "date", "time", "note"])
        #expect(e.name == "Zápočet" && e.date == "2026-11-02" && e.time == "")
        draft.hasTime = true
        draft.time = clock.date(at(11, 2, 8, 30))
        e = draft.record(clock: clock)
        #expect(e.time == "08:30")

        let edited = ExamDraft(editing: e, now: now, clock: clock)
        #expect(edited.hasTime && clock.ms(edited.time) == at(11, 2, 8, 30))
        #expect(!ExamDraft(editing: Exam(raw: ["id": "x", "date": "2026-11-02", "time": "25:00"]), now: now, clock: clock).hasTime)
    }
}
