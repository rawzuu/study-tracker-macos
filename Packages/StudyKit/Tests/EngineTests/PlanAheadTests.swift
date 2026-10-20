import Core
import Foundation
import Testing
@testable import Engine

// Chování, které má jen Mac: plán na víc dní, předmět místo „Pokračovat: téma“, rozvrh bez dvojích hodin.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let min = StudyClock.minute

/// Říjen 2026 v `h:m` (19. 10. je pondělí).
private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!)
}

private func day(_ d: Int) -> Int { clock.startOfDay(at(d, 12)) }

private func subject(_ id: String, goal: Int = 300) -> Subject {
    Subject(raw: ["id": .string(id), "name": .string(id.uppercased()), "color": "#7b8cde", "weeklyGoalMin": .number(Double(goal)), "archived": false])
}

private func session(_ subject: String, _ start: Int, minutes: Int = 50, topic: String = "") -> Session {
    Session(raw: [
        "id": .string(Session.newID()), "mode": "pomodoro", "interruptions": 0, "subjectId": .string(subject), "topic": .string(topic),
        "start": .number(Double(start)), "end": .number(Double(start + minutes * min)), "durationSec": .number(Double(minutes * 60)), "note": "",
    ])
}

private func block(_ id: String, _ subject: String, _ start: Int, minutes: Int = 50, done: Bool = false) -> PlanBlock {
    PlanBlock(raw: ["id": .string(id), "subjectId": .string(subject), "title": "", "start": .number(Double(start)),
                    "durationMin": .number(Double(minutes)), "done": .bool(done), "note": ""])
}

/// Tři předměty s týdenním cílem, denní cíl 100 min, naposledy se učilo minulý týden.
private func document(_ build: (inout AppDocument) -> Void = { _ in }) -> AppDocument {
    var d = AppDocument.empty
    d.upsert([subject("a"), subject("b"), subject("c")], now: 1)
    d.upsert([session("a", at(15, 9), topic: "Strukturogramy"), session("b", at(15, 11)), session("c", at(15, 14))], now: 1)
    d.updateSettings(now: 1) { $0.dailyGoalMin = 100 }
    build(&d)
    return d
}

private func placed(_ items: [DayPlanItem]) -> [DayPlanItem] { items.filter { $0.include && $0.isPlaced } }

@Suite("Ranní plán na víc dní")
struct PlanAheadTests {
    let now = at(19, 7, 40)

    @Test("Dnešek je přesně ranní plán")
    func todayIsMorningPlan() {
        let d = document { $0.upsert(block("old", "a", at(18, 9)), now: 2) }
        let plan = DayPlan.propose(d, days: [day(19)], now: now, extra: 1, clock: clock)
        #expect(plan.map(\.day) == [day(19)] && plan[0].now == now)
        #expect(plan[0].items == DayPlan.propose(d, now: now, extra: 1, clock: clock))
        #expect(plan[0].items.contains { $0.carry?.id == "old" }, "dnes se nabídne nedokončený blok ze včerejška")
    }

    @Test("Každý den ve svém rozmezí, bez přesunu nedokončených; předměty se mezi dny střídají")
    func days() {
        let d = document { $0.upsert(block("old", "a", at(18, 9)), now: 2) }
        let plan = DayPlan.propose(d, days: [day(20), day(21), day(22)], now: now, clock: clock)
        #expect(plan.map(\.day) == [day(20), day(21), day(22)])
        for p in plan {
            let range = DayPlan.dayRange(d.settings, day: p.day, clock: clock)
            #expect(p.now == range.start)
            #expect(!placed(p.items).isEmpty)
            #expect(placed(p.items).allSatisfy { $0.start >= range.start && $0.start + $0.minutes * min <= range.end })
            #expect(p.items.allSatisfy { $0.carry == nil })
        }
        // Bez započítání dřívějších dnů by každý den vyšel stejně – takhle se plán mezi dny liší.
        let firsts = plan.map { placed($0.items).map(\.subjectId) }
        #expect(Set(firsts).count > 1)
        #expect(Set(firsts.flatMap { $0 }) == ["a", "b", "c"])
    }

    @Test("Už naplánované bloky: v tom dni zmenší cíl, ve dnech po něm se počítají jako odučené")
    func existingBlocks() {
        let d = document { $0.upsert([block("p1", "a", at(20, 9), minutes: 90), block("p2", "a", at(20, 13), minutes: 90)], now: 2) }
        let plan = DayPlan.propose(d, days: [day(20), day(21)], now: now, clock: clock)
        #expect(placed(plan[0].items).isEmpty, "180 min v plánu pokryje denní cíl 100 min")
        #expect(placed(plan[1].items).first?.subjectId != "a", "předmět a má v úterý 3 h – ve středu přijdou na řadu jiné")
        let alone = DayPlan.propose(d, days: [day(21)], now: now, clock: clock)
        #expect(alone[0].items.map(\.subjectId) == plan[1].items.map(\.subjectId), "i bez plánování úterka se úterní bloky započítají")
    }

    @Test("Zkouška se počítá ode dne plánu: po zkoušce už se na ni nepřipravuje")
    func examDistance() {
        let d = document {
            $0.upsert(Exam(raw: ["id": "x", "subjectId": "a", "name": "Zápočet", "date": "2026-10-21", "time": "", "note": ""]), now: 2)
        }
        let plan = DayPlan.propose(d, days: [day(20), day(22)], now: now, clock: clock)
        #expect(placed(plan[0].items).contains { $0.activity == .exam && $0.subjectId == "a" })
        #expect(!plan[1].items.contains { $0.activity == .exam })
    }

    @Test("Obsazený čas více dnů najednou je stejný jako po dnech")
    func busyDays() {
        let d = document { $0.upsert([block("p1", "a", at(20, 9)), block("p2", "b", at(21, 13))], now: 2) }
        let external = [BusyInterval(start: at(21, 18), end: at(21, 19))]
        let all = DayPlan.busyIntervals(d, days: [day(20), day(21)], excluding: ["p2"], clock: clock, external: external)
        for x in [day(20), day(21)] {
            #expect(all[x] == DayPlan.busyIntervals(d, day: x, excluding: ["p2"], clock: clock, external: external))
        }
    }

    @Test("Dny před dneškem se neplánují")
    func pastDays() {
        #expect(DayPlan.propose(document(), days: [day(18), day(19)], now: now, clock: clock).map(\.day) == [day(19)])
    }
}

@Suite("Předmět místo „Pokračovat: téma“")
struct SubjectFirstTests {
    @Test("Pokračování nemá kontext ani název bloku; plán a zkouška ano")
    func context() {
        let d = document()
        let recs = Recommender(document: d, now: at(19, 10), clock: clock).recommend()
        let a = recs.first { $0.subjectId == "a" }!
        #expect(a.activity == .continue && a.title == "Pokračovat: Strukturogramy", "název jako na webu zůstává")
        #expect(a.context == nil && a.topic == "Strukturogramy", "téma jen předvyplní časovač")

        let withExam = document {
            $0.upsert(Exam(raw: ["id": "x", "subjectId": "a", "name": "Zápočet", "date": "2026-10-20", "time": "", "note": ""]), now: 2)
        }
        let exam = Recommender(document: withExam, now: at(19, 10), clock: clock).recommend().first { $0.subjectId == "a" }!
        #expect(exam.activity == .exam && exam.context == "Příprava na zkoušku: Zápočet")
    }

    @Test("Ranní plán uloží blok pokračování bez „Pokračovat: téma“")
    func savedTitle() {
        let d = document()
        let items = DayPlan.propose(d, now: at(19, 7, 40), clock: clock)
        let cont = items.filter { $0.activity == .continue }
        #expect(!cont.isEmpty && cont.allSatisfy { $0.displayTitle.isEmpty })
        let blocks = DayPlan.blocks(cont, in: d)
        #expect(!blocks.isEmpty && blocks.allSatisfy { $0.title.isEmpty })
    }
}

@Suite("Rozvrh a Apple Kalendář bez dvojích hodin")
struct LectureDuplicateTests {
    private func busy(_ id: String, _ start: Int, _ end: Int) -> ExternalBusy {
        ExternalBusy(id: id, title: id, start: start, end: end, calendarId: "home", calendarTitle: "Domů", color: "#ff9500")
    }

    private func timetable(skipped: [String] = [], hidden: [String] = []) -> Timetable {
        func event(_ key: String, _ series: String, _ start: Int, _ end: Int) -> JSONValue {
            .object(["key": .string(key), "series": .string(series), "title": .string(series), "location": "", "start": .number(Double(start)), "end": .number(Double(end))])
        }
        return Timetable(raw: [
            "id": "tt", "name": "Rozvrh", "importedAt": 1,
            "events": .array([event("l1", "Anatomie", at(19, 9), at(19, 10, 30)), event("l2", "Fyziologie", at(20, 11), at(20, 12, 30))]),
            "hiddenSeries": .array(hidden.map { .string($0) }), "skipped": .array(skipped.map { .string($0) }),
        ])
    }

    @Test("Událost ve stejném čase jako hodina se schová – i u odpadlé hodiny a skryté řady; jiné zůstanou")
    func dedupe() {
        let events = [busy("skola", at(19, 9), at(19, 10, 30)), busy("trenink", at(19, 18), at(19, 19, 30)),
                      busy("posunuto", at(20, 11, 15), at(20, 12, 30)), busy("fyzio", at(20, 11), at(20, 12, 30))]
        var d = AppDocument.empty
        #expect(Timetables.withoutLectures(events, d) == events, "bez rozvrhu se nic neschová")
        d.upsert(timetable(), now: 1)
        #expect(Timetables.withoutLectures(events, d).map(\.id) == ["trenink", "posunuto"])
        var off = AppDocument.empty
        off.upsert(timetable(skipped: ["l1"], hidden: ["Fyziologie"]), now: 1)
        #expect(Timetables.withoutLectures(events, off).map(\.id) == ["trenink", "posunuto"], "odpadlá hodina uvolní čas")
        #expect(Timetables.withoutLectures([], d).isEmpty)
    }
}
