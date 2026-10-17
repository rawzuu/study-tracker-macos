import CoreGraphics
import Core
import Engine
import Foundation
import Testing
@testable import Features

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let min = StudyClock.minute

private func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi))!)
}

/// Týden 19.–25. 10. 2026 (v neděli končí letní čas).
private let week = at(10, 19, 0)
private let now = at(10, 21, 12)

private func doc() -> AppDocument {
    var d = AppDocument.empty
    d.upsert([
        Subject(raw: ["id": "a", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 120, "archived": false]),
        Subject(raw: ["id": "b", "name": "Biochemie", "color": "#8fae8b", "weeklyGoalMin": 0, "archived": false]),
        Subject(raw: ["id": "c", "name": "Cíl bez učení", "color": "#7fa6c9", "weeklyGoalMin": 60, "archived": false]),
        Subject(raw: ["id": "z", "name": "Archiv", "color": "#b48ead", "weeklyGoalMin": 60, "archived": true]),
    ], now: 1)
    func session(_ id: String, _ subject: String, _ start: Int, _ minutes: Int, topic: String = "") -> Session {
        Session(raw: ["id": .string(id), "subjectId": .string(subject), "topic": .string(topic), "start": .number(Double(start)),
                      "end": .number(Double(start + minutes * min)), "durationSec": .number(Double(minutes * 60))])
    }
    d.upsert([
        session("s1", "b", at(10, 20, 9), 30, topic: "Glykolýza"),
        session("s2", "a", at(10, 20, 9, 30), 60),
        session("s3", "b", at(10, 20, 14), 45),
        session("s0", "a", at(10, 18, 10), 60), // minulý týden
    ], now: 1)
    func block(_ id: String, _ subject: String, _ start: Int, _ minutes: Int, done: Bool = false) -> PlanBlock {
        PlanBlock(raw: ["id": .string(id), "subjectId": .string(subject), "title": "", "start": .number(Double(start)),
                        "durationMin": .number(Double(minutes)), "done": .bool(done), "note": ""])
    }
    d.upsert([
        block("hotovo", "a", at(10, 20, 9, 30), 60, done: true), // kryje se se s2
        block("bez-casu", "b", at(10, 22, 8), 30, done: true),
        block("noc", "a", at(10, 24, 23), 90),
        block("pristi", "a", at(10, 26, 9), 30),
    ], now: 1)
    d.upsert(Exam(raw: ["id": "e", "subjectId": "a", "name": "Zápočet", "date": "2026-10-23", "time": "08:30", "note": ""]), now: 1)
    return d
}

@Suite("Stav kalendáře")
struct CalendarStateTests {
    @Test("Vše: hotový blok se zapsaným časem nahradí sezení, blok přes půlnoc je ve dvou dnech")
    func weekAll() {
        let s = CalendarWeekState(document: doc(), weekStart: week, layer: .all, live: nil, now: now, clock: clock)
        #expect(s.title == "19. října – 25. října" && s.isCurrentWeek)
        let ids = s.days.flatMap { $0.items.map(\.id) }
        #expect(ids == ["s-s1", "s-s2", "s-s3", "p-bez-casu", "p-noc", "p-noc~2"])
        #expect(s.days[3].items.first?.done == true) // hotový bez zapsaného času zůstane vidět
        // Za ranní kus bloku přes půlnoc (v neděli) jde blok natáhnout, za večerní ne.
        #expect(s.days[5].items.map(\.item.isLastPart) == [false] && s.days[6].items.map(\.item.isLastPart) == [true])
        #expect(s.days[5].items.first?.timeLabel == "23:00–00:30")
        // Sezení 9:00–9:30 a 9:30–10:30 se nepřekrývají, ale kratší zabírá místo aspoň 20 minut.
        #expect(s.days[1].items.map(\.lane) == [.init(lane: 0, lanes: 1), .init(lane: 0, lanes: 1), .init(lane: 0, lanes: 1)])
        #expect(s.firstHour == 0) // ranní kus bloku přes půlnoc začíná o půlnoci
        #expect(s.studied == "2 h 15 min" && s.planned == "3 h")
    }

    @Test("Plán a Odučeno ukazují jen svou vrstvu")
    func layers() {
        let plan = CalendarWeekState(document: doc(), weekStart: week, layer: .plan, live: nil, now: now, clock: clock)
        #expect(plan.days.flatMap { $0.items.map(\.id) } == ["p-hotovo", "p-bez-casu", "p-noc", "p-noc~2"])
        let done = CalendarWeekState(document: doc(), weekStart: week, layer: .done, live: nil, now: now, clock: clock)
        #expect(done.days.flatMap { $0.items.map(\.id) } == ["s-s1", "s-s2", "s-s3"])
        #expect(done.firstHour == 6)
    }

    @Test("Záhlaví dne: součet, proužek v pořadí z dat, zkoušky; legenda od nejvíc")
    func headers() {
        let s = CalendarWeekState(document: doc(), weekStart: week, layer: .all, live: nil, now: now, clock: clock)
        let tuesday = s.days[1]
        #expect(tuesday.weekday == "Út" && tuesday.number == 20 && tuesday.total == "2 h 15 min")
        #expect(tuesday.mix.map(\.subject.id) == ["b", "a"] && tuesday.mix.map(\.sec) == [4500, 3600])
        #expect(s.days[2].isToday && s.days[2].total == nil)
        #expect(s.days[4].exams.map(\.name) == ["Zápočet"])
        #expect(s.legend.map(\.subject.name) == ["Biochemie", "Anatomie"])
    }

    @Test("Běžící blok se kreslí od začátku učení, aspoň 10 minut")
    func live() {
        var timer = TimerState(modeId: "pomodoro")
        timer.status = .running
        timer.subjectId = "b"
        timer.topic = "Krebsův cyklus"
        timer.workStartedAt = now - 3 * min
        let s = CalendarWeekState(document: doc(), weekStart: week, layer: .all, live: timer, now: now, clock: clock)
        let live = s.days[2].items.first { $0.item.source == .live }
        #expect(live?.item.start == now - 3 * min && live?.item.end == now + 7 * min && live?.detail == "právě teď")
        timer.status = .ready
        let idle = CalendarWeekState(document: doc(), weekStart: week, layer: .all, live: timer, now: now, clock: clock)
        #expect(!idle.days[2].items.contains { $0.item.source == .live })
    }

    @Test("Měsíc: šest týdnů pro březen se změnou času, čtyři pro únor 2027")
    func monthGrid() {
        let march = CalendarMonthState(document: .empty, monthStart: at(3, 1, 0), layer: .all, now: now, clock: clock)
        #expect(march.cells.count == 42 && march.title == "březen 2026")
        #expect(march.cells.first?.number == 23 && march.cells.first?.inMonth == false)
        let feb = CalendarMonthState(document: .empty, monthStart: clock.parseDayKey("2027-02-01")!, layer: .all, now: now, clock: clock)
        #expect(feb.cells.count == 28)
        #expect(CalendarMonthState.shift(at(12, 1, 0), by: 1, clock: clock) == clock.parseDayKey("2027-01-01"))
    }

    @Test("Měsíc: odučeno po předmětech, hotové bloky jen ve vrstvě Plán")
    func monthCells() {
        let all = CalendarMonthState(document: doc(), monthStart: at(10, 1, 0), layer: .all, now: now, clock: clock)
        let tuesday = all.cells.first { $0.day == at(10, 20, 0) }!
        #expect(tuesday.total == "2 h 15 min" && tuesday.subjects.map(\.subject.id) == ["b", "a"])
        #expect(tuesday.plans.isEmpty && tuesday.mixWidth == 1)
        let plan = CalendarMonthState(document: doc(), monthStart: at(10, 1, 0), layer: .plan, now: now, clock: clock)
        let planTuesday = plan.cells.first { $0.day == at(10, 20, 0) }!
        #expect(planTuesday.total == nil && planTuesday.plans.map(\.id) == ["hotovo"] && planTuesday.plans.first?.done == true)
        #expect(all.cells.first { $0.day == at(10, 23, 0) }?.exams.map(\.id) == ["e"])
    }

    @Test("Plán vs. realita: předměty s plánem, učením nebo cílem; archivované jen s plánem nebo učením")
    func planVsReality() {
        let rows = PlanVsRealityRow.rows(document: doc(), weekStart: week, clock: clock)
        #expect(rows.map(\.subject.id) == ["a", "b", "c"])
        let a = rows[0]
        #expect(a.studiedSec == 3600 && a.plannedSec == 9000 && a.goalSec == 7200) // blok příští týden se nepočítá
        #expect(abs(a.fraction - 0.4) < 1e-9)
        #expect(rows[2].fraction == 0)
        #expect(PlanVsRealityRow(subject: rows[1].subject, studiedSec: 60, plannedSec: 0, goalSec: 0).fraction == 1)
        #expect(a.detail == "odučeno · plán 2 h 30 min · cíl 2 h")
    }

    @Test("Nadcházející zkoušky: termín, odpočet a barva podle blízkosti")
    func exams() {
        let rows = UpcomingExamRow.rows(document: doc(), now: now, clock: clock)
        #expect(rows.count == 1)
        #expect(rows[0].when == "23. října 08:30" && rows[0].countdown == "za 2 dny" && rows[0].tone == .soon)
    }

    @Test("Tažení: dny podle šířky sloupce, čas po 15 min, délka po 5 min v mezích")
    func dragMath() {
        let move = BlockDrag.move("b", translation: CGSize(width: -150, height: 30), columnWidth: 100)
        // −1,5 dne → −1 a 37,5 min = 2,5 čtvrthodiny → 3 (Math.round zaokrouhluje poloviny nahoru)
        #expect(move.dayDelta == -1 && move.minDelta == 45)
        #expect(BlockDrag.move("b", translation: CGSize(width: 40, height: -6), columnWidth: 100).isNoOp)
        #expect(BlockDrag.resize("b", translation: -200, durationMin: 30).durDelta == -20) // nejméně 10 min
        #expect(BlockDrag.resize("b", translation: 1000, durationMin: 700).durDelta == 20) // nejvýš 12 h
        #expect(BlockDrag.resize("b", translation: 13, durationMin: 60).durDelta == 15)
        // Přes změnu času drží blok místní čas: so 24. 10. 9:00 + 1 den = ne 25. 10. 9:00
        #expect(BlockDrag(blockId: "b", dayDelta: 1).movedStart(at(10, 24, 9), clock: clock) == at(10, 25, 9))
        #expect(BlockDrag.slotStart(y: 100, day: week, firstHour: 6, clock: clock) == at(10, 19, 8))
    }
}
