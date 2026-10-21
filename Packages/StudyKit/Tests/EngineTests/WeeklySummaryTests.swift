import Core
import Foundation
import Testing
@testable import Engine

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private func at(_ m: Int, _ d: Int, _ h: Int) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!)
}

private func session(_ id: String, _ start: Int, minutes: Int) -> Session {
    Session(raw: ["id": .string(id), "subjectId": "anat", "start": .number(Double(start)), "end": .number(Double(start + minutes * 60_000)),
                  "durationSec": .number(Double(minutes * 60)), "mode": "pomodoro", "note": ""])
}

@Suite("Pondělní souhrn týdne")
struct WeeklySummaryTests {
    @Test("Čas proti cíli, nejlepší den, změna a blížící se zkouška")
    func full() {
        var doc = AppDocument.empty
        doc.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#7d9cc0", "weeklyGoalMin": 600, "archived": false]), now: 1)
        // týden 12.–18. 10.: Po 2 h, St 3 h; týden předtím 4 h
        doc.upsert([session("a", at(10, 12, 9), minutes: 120), session("b", at(10, 14, 18), minutes: 180), session("c", at(10, 7, 10), minutes: 240)], now: 1)
        doc.upsert(Exam(raw: ["id": "e", "subjectId": "anat", "name": "Zápočet z anatomie", "date": "2026-10-22"]), now: 1)
        let text = WeeklySummary.make(doc, now: at(10, 19, 9), clock: clock)
        #expect(text?.title == "Minulý týden: 5 h")
        #expect(text?.body == "50 % týdenního cíle (10 h) · nejvíc ve středu (3 h) · +25 % proti týdnu předtím. Blíží se: Zápočet z anatomie za 3 dny.")
    }

    @Test("Bez učení, cílů i zkoušek se nic neposílá; bez učení s cílem ano")
    func empty() {
        var doc = AppDocument.empty
        #expect(WeeklySummary.make(doc, now: at(10, 19, 9), clock: clock) == nil)
        doc.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#7d9cc0", "weeklyGoalMin": 300, "archived": false]), now: 1)
        let text = WeeklySummary.make(doc, now: at(10, 19, 9), clock: clock)
        #expect(text == .init(title: "Minulý týden bez učení", body: "0 % týdenního cíle (5 h)."))
        #expect(WeeklySummary.week(now: at(10, 21, 12), clock: clock) == clock.startOfDay(at(10, 12, 12)))
    }
}
