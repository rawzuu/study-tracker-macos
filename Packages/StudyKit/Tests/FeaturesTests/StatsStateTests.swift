import Core
import Foundation
import Testing
@testable import Engine
@testable import Features

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private func at(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 10) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!)
}

private func session(_ id: String, _ subject: String, _ start: Int, min: Int, focus: Int? = nil, mode: String = "pomodoro", interruptions: Int = 0) -> Session {
    var raw: JSONObject = ["id": .string(id), "subjectId": .string(subject), "start": .number(Double(start)), "end": .number(Double(start + min * 60_000)),
                           "durationSec": .number(Double(min * 60)), "topic": "", "mode": .string(mode), "interruptions": .number(Double(interruptions)), "note": ""]
    if let focus { raw["focus"] = .number(Double(focus)) }
    return Session(raw: raw)
}

/// Pondělí 19. 10. 2026 večer; v posledních 7 dnech 5 h 50 min, v týdnu předtím 2 h.
private func document() -> AppDocument {
    var d = AppDocument.empty
    d.upsert([
        Subject(raw: ["id": "a", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 300]),
        Subject(raw: ["id": "b", "name": "Biochemie", "color": "#7fa6c9", "weeklyGoalMin": 0]),
    ], now: 1)
    d.upsert([
        session("1", "a", at(13, 9), min: 50, focus: 4), session("2", "a", at(14, 9), min: 50, focus: 4), session("3", "b", at(15, 22, 30), min: 90, focus: 2),
        session("4", "a", at(17, 23), min: 60, focus: 2, interruptions: 1), session("5", "b", at(19, 8), min: 100, focus: 5),
        session("6", "a", at(19, 10), min: 0, mode: "anki"),
        session("old1", "a", at(8, 9), min: 60), session("old2", "b", at(9, 9), min: 60),
    ], now: 2)
    d.updateSettings(now: 3) { $0.dailyGoalMin = 90 }
    return d
}

@Suite("Statistiky")
struct StatsStateTests {
    let now = at(19, 20)

    @Test("Souhrn období a srovnání s předchozím obdobím stejné délky")
    func facts() {
        let s = StatsState(document: document(), period: .week, subjectId: nil, now: now, clock: clock)
        #expect(s.days == 7 && s.totalSec == (50 + 50 + 90 + 60 + 100) * 60)
        #expect(s.change == Int(JS.round(Double(350 - 120) / 120 * 100)))
        #expect(s.activeDays == 5 && s.blocks == 5 && s.ankiBlocks == 1)
        #expect(s.avgBlockSec == Double(350 * 60) / 5)
        #expect(s.focus == Double(4 + 4 + 2 + 2 + 5) / 5)
        #expect(s.subjects.map(\.subject.id) == ["b", "a"], "190 min Biochemie, 160 min Anatomie")
        #expect(s.subjects.map(\.percent) == [54, 46] && s.subjects[1].sessions == 4)
        #expect(s.trend.count == 7 && s.trend.last?.minutes == 100 && s.goalMinutes == 90)
        #expect(s.hours[22].minutes > 0 && s.hours[8].focus == 5)
    }

    @Test("Filtr předmětu: bez denního cíle, rok jen pro předmět")
    func subjectFilter() {
        let s = StatsState(document: document(), period: .month, subjectId: "a", now: now, clock: clock)
        #expect(s.subjects.map(\.subject.id) == ["a"] && s.goalMinutes == 0)
        #expect(s.year.count == 365 && s.year.reduce(0) { $0 + $1.minutes } == 50 + 50 + 60 + 60)
        #expect(s.change == nil, "před 30 dny nic")
    }

    @Test("Předměty v čase po týdnech, u roku po měsících")
    func buckets() {
        let week = StatsState(document: document(), period: .month, subjectId: nil, now: now, clock: clock)
        // 20. 9. (neděle) → od pondělí 14. 9.: šest týdnů do 19. 10.
        #expect(!week.byMonths && Set(week.stacked.map(\.bucket)).count == 6)
        let year = StatsState(document: document(), period: .year, subjectId: nil, now: now, clock: clock)
        #expect(year.byMonths && Set(year.stacked.map(\.bucket)).count == 13)
        #expect(year.stacked.filter { $0.subject.id == "b" }.reduce(0) { $0 + $1.minutes } == 250)
    }

    @Test("Postřehy: učení po 22. hodině")
    func insights() {
        var d = document()
        d.upsert([session("7", "a", at(18, 22, 10), min: 40), session("8", "b", at(16, 23), min: 30)], now: 4)
        let s = StatsState(document: d, period: .week, subjectId: nil, now: now, clock: clock)
        #expect(s.insights.contains { $0.hasPrefix("Víc než 30 % učení máš po 22. hodině") })
        #expect(StatsState(document: .empty, period: .week, subjectId: nil, now: now, clock: clock).isEmpty)
    }
}
