import Core
import Foundation
import Testing
@testable import Engine

// Čitelné ukázky; úplné srovnání s webem je v PlannerParityTests.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
private let min = StudyClock.minute

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!)
}

private func block(_ id: String, _ start: Int, _ minutes: Int) -> CalendarItem {
    CalendarItem(id: id, source: .block(id: id), subjectId: "a", start: start, end: start + minutes * min, title: "")
}

private func session(_ id: String, _ start: Int, _ minutes: Int) -> CalendarItem {
    CalendarItem(id: id, source: .session(id: id), subjectId: "a", start: start, end: start + minutes * min, title: "")
}

@Suite("Kalendář – ukázky")
struct PlannerTests {
    @Test("Překrývající se položky jdou vedle sebe, navazující pod sebe")
    func lanes() {
        let lanes = CalendarLayout.lanes([
            block("ráno", at(19, 9), 60),
            session("učení", at(19, 9, 30), 60),
            block("pak", at(19, 10), 30), // ráno už skončilo → první sloupec je volný
            block("večer", at(19, 18), 45),
        ])
        #expect(lanes["ráno"] == .init(lane: 0, lanes: 2))
        #expect(lanes["učení"] == .init(lane: 1, lanes: 2))
        #expect(lanes["pak"] == .init(lane: 0, lanes: 2))
        #expect(lanes["večer"] == .init(lane: 0, lanes: 1))
    }

    @Test("Krátká položka zabírá místo jako 20 minut")
    func shortItems() {
        let lanes = CalendarLayout.lanes([session("5 min", at(19, 9), 5), session("hned po", at(19, 9, 10), 30)])
        #expect(lanes["hned po"] == .init(lane: 1, lanes: 2))
    }

    @Test("Shodný začátek: plán před sezením, bloky plánu v pořadí, jaké dá řazení na webu")
    func ties() {
        let lanes = CalendarLayout.lanes([session("s", at(19, 9), 30), block("p1", at(19, 9), 30), block("p2", at(19, 9), 30)])
        #expect(lanes["p2"]?.lane == 0)
        #expect(lanes["p1"]?.lane == 1)
        #expect(lanes["s"]?.lane == 2)
    }

    @Test("Blok přes půlnoc se rozdělí; natáhnout jde jen ranní kus")
    func split() {
        let parts = CalendarLayout.splitAtMidnight(block("noc", at(19, 23), 90), clock: clock)
        #expect(parts.map(\.id) == ["noc", "noc~2"])
        #expect(parts[0].end == at(20, 0) && parts[1].start == at(20, 0) && parts[1].end == at(20, 0, 30))
        #expect(parts.allSatisfy { $0.fullStart == at(19, 23) && $0.fullEnd == at(20, 0, 30) })
        #expect(parts.map(\.isLastPart) == [false, true])
        #expect(CalendarLayout.splitAtMidnight(block("den", at(19, 22), 120), clock: clock).count == 1)
    }

    @Test("Mřížka začíná v 6:00, nebo dřív, když se učilo po půlnoci")
    func firstHour() {
        #expect(CalendarLayout.firstHour([block("a", at(19, 9), 30)], clock: clock) == 6)
        #expect(CalendarLayout.firstHour([block("a", at(19, 9), 30), session("noc", at(20, 1, 15), 30)], clock: clock) == 1)
    }

    @Test("Zápis z bloku: proběhlá část, nebo celý blok jako právě skončený")
    func loggedSpan() {
        let b = PlanBlock(raw: ["start": .number(Double(at(19, 9))), "durationMin": 50])
        #expect(PlanMatch.loggedSpan(of: b, now: at(19, 9, 20)) == (at(19, 9), 20))
        #expect(PlanMatch.loggedSpan(of: b, now: at(19, 12)) == (at(19, 9), 50))
        #expect(PlanMatch.loggedSpan(of: b, now: at(19, 9) + 10_000) == (at(19, 9), 1))
        #expect(PlanMatch.loggedSpan(of: b, now: at(19, 8)) == (at(19, 8) - 50 * min, 50))
    }

    @Test("Math.round a řazení jako ve V8")
    func jsCompat() {
        #expect([-2.5, -0.5, 0.5, 2.5, 2.4999].map(JS.round) == [-2, 0, 1, 3, 2])
        let alwaysBefore = { (_: String, _: String) in -1 }
        #expect(JS.sort(["a", "b", "c"], by: alwaysBefore) == ["c", "b", "a"])
        #expect(JS.sort([3, 1, 2], by: { $0 - $1 }) == [1, 2, 3])
        #expect(JS.sort(Array((0..<100).reversed()), by: { $0 - $1 }) == Array(0..<100))
    }
}
