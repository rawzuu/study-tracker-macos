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

    @Test("Nové sezení odškrtne svůj blok i bloky, se kterými se kryje; úprava plán nemění")
    func saveSession() {
        func plan(_ id: String, _ subject: String, _ start: Int, done: Bool = false) -> PlanBlock {
            PlanBlock(raw: ["id": .string(id), "subjectId": .string(subject), "title": "", "start": .number(Double(start)), "durationMin": 60, "done": .bool(done), "note": ""])
        }
        var doc = AppDocument.empty
        doc.upsert([plan("vlastní", "a", at(19, 15)), plan("kryje", "a", at(19, 9)), plan("jiný", "b", at(19, 9)), plan("hotový", "a", at(19, 9, 30), done: true)], now: 1)
        let session = Session(raw: ["id": "s", "subjectId": "a", "start": .number(Double(at(19, 9))), "end": .number(Double(at(19, 10))), "durationSec": 3600])
        var edited = doc
        edited.saveSession(session, isNew: false, planBlockId: "vlastní", now: 5)
        #expect(edited.alive(PlanBlock.self).filter(\.done).map(\.id) == ["hotový"])

        doc.saveSession(session, isNew: true, planBlockId: "vlastní", now: 5)
        #expect(doc.alive(PlanBlock.self).filter(\.done).map(\.id).sorted() == ["hotový", "kryje", "vlastní"])
        #expect(doc.record(PlanBlock.self, id: "hotový")?.updatedAt == 1) // už hotový se znovu nezapisuje
        #expect(doc.record(Session.self, id: "s")?.createdAt == 5)
    }

    @Test("Smazaná zkouška vezme s sebou budoucí nedokončené bloky a „Vrátit“ je vrátí spolu")
    func removeExam() {
        let now = at(19, 12)
        func plan(_ id: String, _ start: Int, done: Bool = false, exam: String? = "e") -> PlanBlock {
            var raw: JSONObject = ["id": .string(id), "subjectId": "a", "title": "", "start": .number(Double(start)), "durationMin": 45, "done": .bool(done), "note": ""]
            if let exam { raw["examId"] = .string(exam) }
            return PlanBlock(raw: raw)
        }
        var doc = AppDocument.empty
        doc.upsert(Exam(raw: ["id": "e", "subjectId": "a", "name": "Zápočet", "date": "2026-11-02", "time": "", "note": ""]), now: 1)
        doc.upsert([plan("zítra", at(20, 17)), plan("včera", at(18, 17)), plan("hotový", at(21, 17), done: true), plan("ruční", at(21, 17), exam: nil)], now: 1)
        #expect(doc.upcomingBlocks(ofExam: "e", now: now).map(\.id) == ["zítra"])

        doc.removeExam("e", now: now)
        #expect(doc.alive(Exam.self).isEmpty)
        #expect(doc.alive(PlanBlock.self).map(\.id) == ["včera", "hotový", "ruční"])
        #expect(doc.record(PlanBlock.self, id: "zítra")?.deletedAt == now)

        doc.restore(.exams, id: "e", now: now + 60_000)
        #expect(doc.alive(Exam.self).count == 1)
        #expect(doc.alive(PlanBlock.self).count == 4)
        #expect(doc.record(PlanBlock.self, id: "zítra")?.raw["deletedAt"] == nil)
    }

    @Test("Odpočet do zkoušky a nadcházející zkoušky podle data")
    func countdown() {
        let now = at(19, 23, 30)
        let exam = { (date: String) in Exam(raw: ["id": .string(date), "date": .string(date)]) }
        #expect(ExamCountdown.daysLeft(exam("2026-10-19"), now: now, clock: clock) == 0)
        #expect(ExamCountdown.daysLeft(exam("2026-10-26"), now: now, clock: clock) == 7) // přes změnu času
        #expect(ExamCountdown.daysLeft(exam("nesmysl"), now: now, clock: clock) == nil)
        #expect([0, 1, 3, 5].map { ExamCountdown.label(daysLeft: $0) } == ["dnes", "za 1 den", "za 3 dny", "za 5 dní"])
        var doc = AppDocument.empty
        doc.upsert(["2026-11-02", "2026-10-18", "2026-10-19", "2026-10-25"].map(exam), now: 1)
        #expect(ExamCountdown.upcoming(doc, now: now, clock: clock).map(\.date) == ["2026-10-19", "2026-10-25", "2026-11-02"])
    }
}
