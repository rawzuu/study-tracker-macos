import Core
import Foundation
import Testing
@testable import Engine

// Čitelné ukázky a chování, které má jen Mac; úplné srovnání s webem je v AdviceParityTests.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let min = StudyClock.minute

/// Sobota 17. 10. 2026 v `h:m` (den `d`).
private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!)
}

private func subject(_ id: String, goal: Int = 300) -> Subject {
    Subject(raw: ["id": .string(id), "name": .string(id.uppercased()), "color": "#7b8cde", "weeklyGoalMin": .number(Double(goal)), "archived": false])
}

private func session(_ subject: String, _ start: Int, minutes: Int = 50, topic: String = "", focus: Int? = nil, mode: String = "pomodoro") -> Session {
    var raw: JSONObject = [
        "id": .string(Session.newID()), "mode": .string(mode), "interruptions": 0, "subjectId": .string(subject), "topic": .string(topic),
        "start": .number(Double(start)), "end": .number(Double(start + minutes * min)), "durationSec": .number(Double(minutes * 60)), "note": "",
    ]
    if let focus { raw["focus"] = .number(Double(focus)) }
    return Session(raw: raw)
}

private func doc(_ build: (inout AppDocument) -> Void) -> AppDocument {
    var d = AppDocument.empty
    build(&d)
    return d
}

@Suite("Co teď? a ranní plán – ukázky")
struct AdviceTests {
    let now = at(17, 10)

    @Test("Bez předmětů nic")
    func empty() {
        #expect(Recommender(document: .empty, now: now, clock: clock).recommend().isEmpty)
        #expect(DayPlan.propose(.empty, now: now, clock: clock).isEmpty)
    }

    @Test("Blízká zkouška má přednost a doporučí přípravu; ostatní předměty zůstanou")
    func exam() {
        let d = doc {
            $0.upsert([subject("a"), subject("b")], now: 1)
            $0.upsert(Exam(raw: ["id": "e", "subjectId": "a", "name": "Zápočet", "date": "2026-10-19", "time": "", "note": ""]), now: 1)
            $0.upsert(session("b", at(11, 9)), now: 1)
        }
        let recs = Recommender(document: d, now: now, clock: clock).recommend()
        #expect(recs.map(\.subjectId) == ["a", "b"])
        #expect(recs[0].activity == .exam && recs[0].title == "Příprava na zkoušku: Zápočet")
        #expect(recs[0].reasons.first == "zkouška za 2 dny")
    }

    @Test("Předmět učený před chvílí se prostřídá")
    func interleaving() {
        let d = doc {
            $0.upsert([subject("a"), subject("b")], now: 1)
            $0.upsert([session("a", now - 90 * min, minutes: 80, topic: "Derivace"), session("b", at(15, 9), topic: "Optika")], now: 1)
        }
        let recs = Recommender(document: d, now: now, clock: clock).recommend()
        #expect(recs.first?.subjectId == "b")
        #expect(recs.first?.title == "Pokračovat: Optika")
        #expect(recs.first { $0.subjectId == "a" }!.signals.X > 0.5)
    }

    @Test("Témata k opakování Mac nečte – doporučení jsou stejná jako bez nich")
    func ignoresTopics() {
        let base = doc {
            $0.upsert([subject("a"), subject("b", goal: 0)], now: 1)
            $0.upsert(session("b", at(16, 9)), now: 1)
        }
        var withTopics = base
        withTopics.upsert([
            Topic(raw: ["id": "t1", "subjectId": "a", "name": "Limity", "stage": 1, "nextReviewAt": .number(Double(now - StudyClock.day)), "reviews": 2, "mastered": false]),
            Topic(raw: ["id": "t2", "subjectId": "b", "name": "Řady", "stage": -1, "reviews": 0, "mastered": false]),
        ], now: 1)
        let plain = Recommender(document: base, now: now, clock: clock).recommend()
        #expect(Recommender(document: withTopics, now: now, clock: clock).recommend() == plain)
        #expect(plain.allSatisfy { $0.signals.R == 0 && $0.activity != .anki })
        #expect(DayPlan.propose(withTopics, now: now, clock: clock) == DayPlan.propose(base, now: now, clock: clock))
    }

    @Test("Kartičky z dnešního stavu Anki – česky správně a s odhadem času")
    func anki() {
        let d = doc {
            $0.upsert(subject("a"), now: 1)
            $0.upsert(AnkiSnapshot(raw: [
                "id": "snapshot", "at": .number(Double(at(17, 8))), "reviewedToday": 0, "msToday": 0,
                "decks": [["name": "Anatomie", "newCount": 1, "learnCount": 0, "reviewCount": 2, "total": 100]],
            ]), now: 1)
        }
        let anki = Recommender(document: d, now: now, clock: clock).recommend().first { $0.activity == .anki }
        #expect(anki?.title == "Anki: 3 karty")
        #expect(anki?.subjectId == nil && anki?.minutes == 5)
        #expect(anki?.reasons == ["odhad ~5 min podle tvého tempa (10 s na odpověď)", "1 nová karta se dnes ukáže víckrát"])
        // včerejší stav se nepočítá
        let yesterday = Recommender(document: d, now: at(18, 10), clock: clock).recommend()
        #expect(!yesterday.contains { $0.activity == .anki })
    }

    @Test("Hláška nad doporučením: pozdní hodina, splněný cíl")
    func note() {
        let d = doc {
            $0.upsert(subject("a"), now: 1)
            $0.upsert(session("a", at(17, 6), minutes: 190), now: 1)
        }
        #expect(Recommender.contextNote(d, now: at(17, 23, 30), clock: clock)?.hasPrefix("Je pozdě") == true)
        #expect(Recommender.contextNote(d, now: at(17, 12), clock: clock)?.hasPrefix("Dnešní cíl máš splněný") == true)
        #expect(Recommender.contextNote(.empty, now: at(17, 12), clock: clock) == nil)
    }

    @Test("Ranní plán: nepřekrývá výuku ani plán, střídá předměty, drží se rozmezí dne")
    func proposal() {
        let lecture = TimetableEvent(raw: [
            "key": "Anatomie@1", "series": "Anatomie", "title": "Anatomie", "location": "",
            "start": .number(Double(at(17, 12))), "end": .number(Double(at(17, 13, 30))),
        ])
        let d = doc {
            $0.upsert(["a", "b", "c"].map { subject($0) }, now: 1)
            $0.upsert(Timetables.new(name: "Rozvrh", events: [lecture], now: 1), now: 1)
            $0.upsert(PlanBlock(raw: ["id": "p", "subjectId": "a", "title": "", "start": .number(Double(at(17, 15))), "durationMin": 60, "done": false, "note": ""]), now: 1)
            $0.updateSettings(now: 1) { $0.dailyGoalMin = 240 }
        }
        let items = DayPlan.propose(d, now: at(17, 8), clock: clock).filter(\.include)
        #expect(items.reduce(0) { $0 + $1.minutes } >= 150)
        let busy = DayPlan.busyIntervals(d, day: at(17, 0), clock: clock) + items.map { BusyInterval(start: $0.start, end: $0.start + $0.minutes * min) }
        let sorted = busy.sorted { $0.start < $1.start }
        for (x, y) in zip(sorted, sorted.dropFirst()) { #expect(y.start >= x.end) }
        #expect(items.allSatisfy { $0.start >= at(17, 8) && $0.start + $0.minutes * min <= at(17, 22) })
        for (x, y) in zip(items, items.dropFirst()) { #expect(x.subjectId != y.subjectId) }
    }

    @Test("Nedokončený blok ze včerejška se nabídne k přesunutí a uloží se do původního záznamu")
    func carry() {
        let d = doc {
            $0.upsert(subject("a"), now: 1)
            $0.upsert(PlanBlock(raw: ["id": "old", "subjectId": "a", "title": "Kapitola 3", "start": .number(Double(at(16, 15))), "durationMin": 50, "done": false, "note": "x", "custom": true]), now: 1)
        }
        let items = DayPlan.propose(d, now: at(17, 8), clock: clock)
        let carry = items.first { $0.activity == .carry }
        #expect(carry?.title == "Kapitola 3" && carry?.reasons == ["nedokončeno včera"])
        let blocks = DayPlan.blocks(items, in: d)
        let moved = blocks.first { $0.id == "old" }
        #expect(moved?.start == carry?.start && moved?.raw["custom"] == .bool(true) && moved?.note == "x")
        // nové bloky: pořadí klíčů jako na webu, důvody jako poznámka
        let fresh = blocks.first { $0.id != "old" }
        #expect(fresh?.raw.keys == ["id", "subjectId", "title", "start", "durationMin", "done", "note"])
        #expect(fresh?.note == items.first { $0.carry == nil }?.reasons.joined(separator: " · "))
    }

    @Test("Co se nevejde, zůstane nezaškrtnuté a na konci")
    func overflow() {
        let d = doc {
            $0.upsert([subject("a"), subject("b")], now: 1)
            $0.updateSettings(now: 1) { $0.dailyGoalMin = 600 }
        }
        let items = DayPlan.propose(d, now: at(17, 20), clock: clock)
        #expect(items.contains { !$0.isPlaced && !$0.include })
        #expect(items.drop(while: \.isPlaced).allSatisfy { !$0.isPlaced })
    }

    @Test("Rozmezí dne: neplatný nebo chybějící čas je 0, přes půlnoc do dalšího dne")
    func dayRange() {
        var s = AppDocument.empty.settings
        s.planDayStart = ""
        s.planDayEnd = "24:00"
        let r = DayPlan.dayRange(s, day: at(17, 0), clock: clock)
        #expect(r.start == at(17, 0) && r.end == at(18, 0))
        s.planDayStart = "7"
        s.planDayEnd = "8a:30"
        let r2 = DayPlan.dayRange(s, day: at(17, 0), clock: clock)
        #expect(r2.start == at(17, 7) && r2.end == at(17, 0, 30))
    }
}
