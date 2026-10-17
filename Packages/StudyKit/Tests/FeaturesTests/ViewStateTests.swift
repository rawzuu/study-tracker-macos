import Core
import Engine
import Foundation
import Testing
@testable import Features

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!)
}

/// Sobota 17. 10. 2026 15:00 – týden začal v pondělí 12. 10.
private let now = at(2026, 10, 17, 15)

private func sampleDocument() -> AppDocument {
    var d = AppDocument.empty
    d.upsert([
        Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 360]),
        Subject(raw: ["id": "lat", "name": "Latina", "color": "#b48ead", "weeklyGoalMin": 0]),
        Subject(raw: ["id": "fyz", "name": "Fyziologie", "color": "#7fa6c9", "weeklyGoalMin": 120]),
        Subject(raw: ["id": "old", "name": "Chemie", "color": "#999999", "weeklyGoalMin": 60, "archived": true]),
    ], now: 1)
    func s(_ id: String, _ subject: String, _ start: Int, min: Int, focus: Int? = nil, topic: String = "", mode: String = "pomodoro") -> Session {
        var raw: JSONObject = ["id": .string(id), "subjectId": .string(subject), "start": .number(Double(start)),
                               "end": .number(Double(start + min * 60_000)), "durationSec": .number(Double(min * 60)),
                               "topic": .string(topic), "mode": .string(mode), "interruptions": 0, "note": ""]
        if let focus { raw["focus"] = .number(Double(focus)) }
        return Session(raw: raw)
    }
    d.upsert([
        s("a", "anat", at(2026, 10, 17, 9), min: 50, focus: 4, topic: "Lebka"),
        s("b", "lat", at(2026, 10, 17, 11), min: 25, focus: 0),
        s("c", "anat", at(2026, 10, 16, 20), min: 60, focus: 5),
        s("d", "fyz", at(2026, 10, 12, 8), min: 30, mode: "manual"),
        s("e", "anat", at(2026, 10, 10, 8), min: 40),  // minulý týden (sobota)
        s("f", "smazany", at(2026, 10, 15, 8), min: 10),
    ], now: 2)
    d.remove(.sessions, id: "f", now: 3)
    d.upsert(PlanBlock(raw: ["id": "p2", "subjectId": "fyz", "title": "Ledviny", "start": .number(Double(at(2026, 10, 17, 17))), "durationMin": 45, "done": false]), now: 4)
    d.upsert(PlanBlock(raw: ["id": "p1", "subjectId": "anat", "title": "", "start": .number(Double(at(2026, 10, 17, 9))), "durationMin": 50, "done": true]), now: 4)
    d.upsert(PlanBlock(raw: ["id": "p0", "subjectId": "anat", "title": "zítra", "start": .number(Double(at(2026, 10, 18, 9))), "durationMin": 50, "done": false]), now: 4)
    d.upsert(Topic(raw: ["id": "t1", "subjectId": "anat", "name": "Lebka", "nextReviewAt": .number(Double(at(2026, 10, 15, 8)))]), now: 5)
    d.upsert(Topic(raw: ["id": "t2", "subjectId": "fyz", "name": "Srdce", "nextReviewAt": .number(Double(at(2026, 10, 17, 23)))]), now: 5)
    d.upsert(Topic(raw: ["id": "t3", "subjectId": "fyz", "name": "Plíce", "nextReviewAt": .number(Double(at(2026, 10, 19, 8)))]), now: 5)
    d.upsert(Exam(raw: ["id": "x1", "subjectId": "anat", "name": "Zápočet", "date": "2026-10-20", "time": "", "note": ""]), now: 6)
    d.upsert(Exam(raw: ["id": "x0", "subjectId": "fyz", "name": "Stará", "date": "2026-10-01", "time": "", "note": ""]), now: 6)
    d.updateSettings(now: 7) { $0.dailyGoalMin = 90 }
    return d
}

@Suite("Stavy obrazovek")
struct ViewStateTests {
    @Test("Přehled: dnešek, týden, cíle, série")
    func dashboard() {
        let s = DashboardState(document: sampleDocument(), now: now, clock: clock)
        #expect(s.title == "Sobota 17. října")
        #expect(s.isoWeek == 42)
        #expect(s.todaySec == 75 * 60)
        #expect(s.goalSec == 90 * 60)
        #expect(s.weekSec == (50 + 25 + 60 + 30) * 60)
        #expect(s.weekGoalSec == (360 + 120) * 60)  // archivovaný předmět se nepočítá
        #expect(s.focus7 == 4.5)
        #expect(s.streak.current == 2)
        // Minulý týden do stejného okamžiku: 40 min → +312,5 %
        #expect(s.weekDelta == Double(165 - 40) / 40)
        #expect(s.weekDays.map(\.sec) == [1800, 0, 0, 0, 3600, 4500, 0])
        #expect(s.weekDays.map(\.isToday) == [false, false, false, false, false, true, false])
        // Nejdřív předměty s cílem v pořadí z Předmětů, pak ostatní, na kterých se pracovalo.
        #expect(s.weekRows.map(\.subject.name) == ["Anatomie", "Fyziologie", "Latina"])
        #expect(s.weekRows.map(\.sec) == [6600, 1800, 1500])
        #expect(!s.isEmpty)
    }

    @Test("Přehled: plán, zkoušky, poslední sezení")
    func dashboardLists() {
        let s = DashboardState(document: sampleDocument(), now: now, clock: clock)
        #expect(s.todayPlan.map(\.id) == ["p1", "p2"])
        #expect(s.todayPlan.map(\.time) == ["09:00", "17:00"])
        #expect(s.todayPlan[0].done)
        #expect(s.exams.map(\.name) == ["Zápočet"])
        #expect(s.exams[0].daysLeft == 3)
        #expect(s.exams[0].day == "út 20. 10.")
        #expect(s.recent.map(\.id) == ["b", "a", "c", "d", "e"])
        #expect(s.recent[0].when == "dnes 11:00")
        #expect(s.recent[2].when == "16. 10. 20:00")
        #expect(s.recent[1].focus == 4 && s.recent[0].focus == nil)
    }

    @Test("Prázdná data")
    func emptyDashboard() {
        let s = DashboardState(document: .empty, now: now, clock: clock)
        #expect(s.isEmpty)
        #expect(s.todaySec == 0 && s.weekRows.isEmpty && s.recent.isEmpty && s.weekDelta == nil && s.focus7 == nil)
    }

    @Test("Historie: po dnech od nejnovějšího, filtr, smazaný předmět")
    func history() {
        let doc = sampleDocument()
        let all = HistoryState(document: doc, subjectId: nil, now: now, clock: clock)
        #expect(all.groups.map(\.title) == ["Dnes", "Včera", "Pondělí 12. října", "Sobota 10. října"])
        #expect(all.groups[0].total == "1 h 15 min")
        #expect(all.groups[0].rows.map(\.id) == ["b", "a"])
        #expect(all.groups[0].rows[1].timeRange == "09:00–09:50")
        #expect(all.groups[0].rows[1].detail == "Lebka · Pomodoro")
        #expect(all.groups[2].rows[0].detail == "Ruční zápis")
        #expect(all.subjects.map(\.name) == ["Anatomie", "Latina", "Fyziologie", "Chemie"])

        let anat = HistoryState(document: doc, subjectId: "anat", now: now, clock: clock)
        #expect(anat.groups.flatMap(\.rows).map(\.id) == ["a", "c", "e"])
    }

    @Test("Smazaný předmět u sezení")
    func deletedSubject() {
        var doc = sampleDocument()
        doc.upsert(Session(raw: ["id": "z", "subjectId": "neexistuje", "start": .number(Double(now - 60_000)), "end": .number(Double(now)), "durationSec": 60]), now: 9)
        let h = HistoryState(document: doc, subjectId: nil, now: now, clock: clock)
        #expect(h.groups[0].rows[0].subject.name == "Smazaný předmět")
    }

    @Test("Předměty: aktivní a archiv, celkový čas a cíl")
    func subjects() {
        let s = SubjectsState(document: sampleDocument(), now: now, clock: clock)
        #expect(s.active.map(\.subject.name) == ["Anatomie", "Latina", "Fyziologie"])
        #expect(s.archived.map(\.subject.name) == ["Chemie"])
        #expect(s.active[0].summary == "Celkem 2 h 30 min · cíl 6 h týdně")
        #expect(s.active[1].summary == "Celkem 25 min")
        #expect(s.active[0].weekSec == 6600)
        #expect(s.active[0].fraction == 6600.0 / 21600)
    }
}
