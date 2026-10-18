import Core
import Foundation
import Testing
@testable import Engine

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let min = StudyClock.minute

/// Říjen 2026 v `h:m` (den `d`).
private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!)
}

private func block(_ id: String, _ start: Int, minutes: Int = 50, title: String = "", done: Bool = false, note: String = "", subject: String = "a") -> PlanBlock {
    PlanBlock(raw: ["id": .string(id), "subjectId": .string(subject), "title": .string(title), "start": .number(Double(start)),
                    "durationMin": .number(Double(minutes)), "done": .bool(done), "note": .string(note)])
}

private var document: AppDocument {
    var d = AppDocument.empty
    d.upsert(Subject(raw: ["id": "a", "name": "Anatomie", "color": "#7b8cde", "weeklyGoalMin": 300, "archived": false]), now: 1)
    d.upsert([
        block("b1", at(19, 9), title: "Lebka"),
        block("b2", at(16, 14), minutes: 25, done: true, note: "kapitola 3"),
        // starší než dva týdny – zůstane v kalendáři, jak je
        block("old", at(1, 9)),
        block("x", at(20, 9), subject: "smazany"),
    ], now: 1)
    d.upsert([
        Exam(raw: ["id": "e1", "subjectId": "a", "name": "Zápočet", "date": "2026-10-22", "time": "", "note": ""]),
        Exam(raw: ["id": "e2", "subjectId": "a", "name": "Zkouška", "date": "2026-11-03", "time": "9:30", "note": "posluchárna A"]),
        Exam(raw: ["id": "e0", "subjectId": "a", "name": "Stará", "date": "2026-09-01", "time": "", "note": ""]),
    ], now: 1)
    return d
}

@Suite("Apple Kalendář – události z dat a rozdíl")
struct CalendarMirrorTests {
    let now = at(18, 10)

    @Test("Bloky od dvou týdnů zpět a zkoušky; hotový blok má ✓ a žádné připomenutí")
    func events() {
        let events = CalendarMirror.events(document, options: .init(includeExams: true, alarmMin: 10), now: now, clock: clock)
        let byId = Dictionary(uniqueKeysWithValues: events.map { ($0.key.id, $0) })
        #expect(Set(byId.keys) == ["b1", "b2", "x", "e1", "e2"])

        let b1 = byId["b1"]!
        #expect(b1.title == "📚 Anatomie – Lebka")
        #expect(b1.start == at(19, 9) && b1.end == at(19, 9, 50) && !b1.allDay)
        #expect(b1.alarms == [10])
        #expect(b1.notes == CalendarMirror.footer)
        #expect(b1.key.url.absoluteString == "studytracker://planovac?blok=b1")

        let b2 = byId["b2"]!
        #expect(b2.title == "✓ 📚 Anatomie")
        #expect(b2.alarms.isEmpty)
        #expect(b2.notes == "kapitola 3\n\n" + CalendarMirror.footer)
        #expect(byId["x"]!.title == "📚 Učení", "předmět, který v datech není")

        let e1 = byId["e1"]!
        #expect(e1.allDay && e1.start == at(22, 0) && e1.title == "🎓 Zápočet (Anatomie)" && e1.alarms == [24 * 60])
        let e2 = byId["e2"]!
        #expect(!e2.allDay && e2.start == clock.atMinutes(clock.parseDayKey("2026-11-03")!, 9 * 60 + 30) && e2.end == e2.start + 90 * min)
        #expect(e2.notes.hasPrefix("posluchárna A"))
    }

    @Test("Bez zkoušek a bez připomenutí")
    func options() {
        let events = CalendarMirror.events(document, options: .init(includeExams: false, alarmMin: nil), now: now, clock: clock)
        #expect(events.allSatisfy { $0.key.kind == .block && $0.alarms.isEmpty })
    }

    @Test("Odkaz události nese, odkud je; cizí odkazy se nepoznají")
    func keys() {
        let key = CalendarMirror.Key(.exam, "e 1/2")
        #expect(CalendarMirror.Key(url: key.url) == key)
        #expect(CalendarMirror.Key(url: URL(string: "studytracker://casovac?start=1")) == nil)
        #expect(CalendarMirror.Key(url: URL(string: "https://planovac?blok=b1")) == nil)
        #expect(CalendarMirror.Key(url: URL(string: "studytracker://planovac?blok=")) == nil)
        #expect(CalendarMirror.Key(url: nil) == nil)
    }

    @Test("Prázdný kalendář: vše se založí; podruhé už nic")
    func createThenNothing() {
        let desired = CalendarMirror.events(document, options: .init(), now: now, clock: clock)
        let first = CalendarMirror.diff(desired: desired, existing: [])
        #expect(first.create.count == desired.count && first.update.isEmpty && first.remove.isEmpty)
        // kalendář vrátí časy na sekundy, poznámku bez koncových mezer a celodenní konec 23:59:59
        let existing = desired.enumerated().map { i, e in
            CalendarMirror.Existing(identifier: "id\(i)", url: e.key.url, title: e.title, start: e.start / 1000 * 1000,
                                    end: e.allDay ? e.start + StudyClock.day - 1000 : e.end, allDay: e.allDay, notes: e.notes + "\n", alarms: e.alarms.reversed())
        }
        #expect(CalendarMirror.diff(desired: desired, existing: existing).isEmpty)
    }

    @Test("Změněný, smazaný, cizí a zdvojený záznam")
    func changes() {
        let desired = CalendarMirror.events(document, options: .init(includeExams: false), now: now, clock: clock)
        func existing(_ id: String, _ e: CalendarMirror.Event) -> CalendarMirror.Existing {
            .init(identifier: id, url: e.key.url, title: e.title, start: e.start, end: e.end, allDay: e.allDay, notes: e.notes, alarms: e.alarms)
        }
        let b1 = desired.first { $0.key.id == "b1" }!
        let b2 = desired.first { $0.key.id == "b2" }!
        var moved = existing("m", b1)
        moved.start += 30 * min
        let gone = CalendarMirror.Event(key: .init(.block, "smazany-blok"), title: "📚 X", start: now, end: now + min, allDay: false, notes: "", alarms: [])
        let changes = CalendarMirror.diff(desired: desired, existing: [
            moved,
            existing("dup1", b2), existing("dup2", b2),
            existing("gone", gone),
            .init(identifier: "foreign", url: nil, title: "Moje", start: now, end: now + min, allDay: false, notes: "", alarms: []),
        ])
        #expect(changes.update == [.init(identifier: "m", event: b1)])
        #expect(changes.create.map(\.key.id) == ["x"])
        #expect(changes.remove == ["dup2", "foreign", "gone"])
    }

    @Test("Ranní plán se vyhne událostem z Apple Kalendáře")
    func dayPlanAvoidsExternal() {
        var d = AppDocument.empty
        d.upsert(Subject(raw: ["id": "a", "name": "A", "color": "#7b8cde", "weeklyGoalMin": 300, "archived": false]), now: 1)
        d.updateSettings(now: 1) { $0.dailyGoalMin = 50 }
        let morning = at(17, 7, 50)
        let free = DayPlan.propose(d, now: morning, clock: clock).filter(\.include)
        let busy = BusyInterval(start: at(17, 7), end: at(17, 12))
        let planned = DayPlan.propose(d, now: morning, clock: clock, external: [busy]).filter(\.include)
        #expect(!free.isEmpty && !planned.isEmpty)
        #expect(free.first!.start < busy.end)
        #expect(planned.allSatisfy { $0.start >= busy.end + 10 * min }, "s pauzou 10 min po události")
        // jiný den nevadí
        let otherDay = BusyInterval(start: at(18, 7), end: at(18, 12))
        #expect(DayPlan.propose(d, now: morning, clock: clock, external: [otherDay]) == DayPlan.propose(d, now: morning, clock: clock))
    }
}
