import Core
import Foundation
import XCTest
@testable import Engine

/// Výkon „Co teď?“ a ranního plánu na velkých syntetických datech (2 roky učení). Výsledky jsou v logu testů;
/// přehled se přepočítává každou minutu a ranní plán po každé úpravě, takže výpočet musí být v jednotkách ms.
final class AdvicePerformanceTests: XCTestCase {
    private static let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)
    private static let now = clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 7))!)

    /// 12 předmětů, ~3 200 sezení za 2 roky, 800 bloků plánu, 20 zkoušek, rozvrh s 300 hodinami.
    static let document: AppDocument = {
        var doc = AppDocument.empty
        let ids = (0..<12).map { "s\($0)" }
        doc.upsert(ids.enumerated().map { i, id in
            Subject(raw: ["id": .string(id), "name": .string("Předmět \(i)"), "color": "#7b8cde", "weeklyGoalMin": .number(Double(60 * (i % 5))), "archived": false])
        }, now: 1)
        let today = clock.startOfDay(now)
        var sessions: [Session] = []
        for d in 0..<730 {
            let day = clock.addDays(today, -d)
            for k in 0..<(d % 4 + 4) / 2 + 4 where (d + k) % 3 != 0 {
                let start = day + (7 + k * 2) * StudyClock.hour + (d * 7 % 50) * StudyClock.minute
                let minutes = [25, 50, 90, 35][(d + k) % 4]
                sessions.append(Session(raw: [
                    "id": .string("x\(d)-\(k)"), "mode": .string(k % 5 == 4 ? "anki" : "pomodoro"), "interruptions": 0,
                    "subjectId": .string(ids[(d + k) % ids.count]), "topic": .string("Téma \(k)"),
                    "start": .number(Double(start)), "end": .number(Double(start + (minutes + 5) * StudyClock.minute)),
                    "durationSec": .number(Double(minutes * 60)), "focus": .number(Double(1 + (d + k) % 5)), "note": .string(k % 5 == 4 ? "\(k * 20) karet" : ""),
                ]))
            }
        }
        doc.upsert(sessions, now: 1)
        doc.upsert((0..<800).map { i in
            PlanBlock(raw: [
                "id": .string("b\(i)"), "subjectId": .string(ids[i % ids.count]), "title": .string("Blok \(i)"),
                "start": .number(Double(clock.addDays(today, -(i / 3) + 30) + (8 + i % 10) * StudyClock.hour)), "durationMin": 50,
                "done": .bool(i % 4 == 0), "note": "",
            ])
        }, now: 1)
        doc.upsert((0..<20).map { i in
            Exam(raw: ["id": .string("e\(i)"), "subjectId": .string(ids[i % ids.count]), "name": .string("Zkouška \(i)"),
                       "date": .string(clock.dayKey(clock.addDays(today, i * 9 - 60))), "time": "", "note": ""])
        }, now: 1)
        let events = (0..<300).map { i in
            let start = clock.atMinutes(clock.addDays(today, i / 3 - 50), [8 * 60, 10 * 60, 14 * 60][i % 3])
            return TimetableEvent(raw: ["key": .string("L\(i)"), "series": .string("Přednáška \(i % 6)"), "title": "Přednáška", "location": "",
                                        "start": .number(Double(start)), "end": .number(Double(start + 90 * StudyClock.minute))])
        }
        doc.upsert(Timetables.new(name: "Rozvrh", events: events, now: 1), now: 1)
        return doc
    }()

    func testRecommendations() {
        let doc = Self.document
        XCTAssertGreaterThan(doc.alive(Session.self).count, 3000)
        measure {
            let recs = Recommender(document: doc, now: Self.now, clock: Self.clock).recommend()
            XCTAssertFalse(recs.isEmpty)
        }
    }

    func testDayPlan() {
        let doc = Self.document
        measure {
            let items = DayPlan.propose(doc, now: Self.now, extra: 2, clock: Self.clock)
            XCTAssertFalse(items.isEmpty)
        }
    }
}
