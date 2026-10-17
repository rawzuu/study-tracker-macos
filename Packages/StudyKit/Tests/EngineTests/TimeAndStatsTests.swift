import Foundation
import Testing
@testable import Engine

// Čitelné ukázky; úplné srovnání s webem je v EngineParityTests.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

/// Okamžik v pražském čase.
private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!)
}

@Suite("Čas a formáty – ukázky")
struct TimeAndStatsTests {
    @Test("Dnes, včera, zítra a tvary data")
    func dayLabel() {
        let now = at(2026, 10, 17, 12)
        #expect(Format.dayLabel(at(2026, 10, 17, 1), now: now, clock: clock) == "Dnes")
        #expect(Format.dayLabel(at(2026, 10, 16, 23), now: now, clock: clock) == "Včera")
        #expect(Format.dayLabel(at(2026, 10, 18, 23), now: now, clock: clock) == "Zítra")
        #expect(Format.dayLabel(at(2026, 10, 8), now: now, clock: clock) == "čtvrtek 8. října")
        #expect(Format.capitalized("čtvrtek 8. října") == "Čtvrtek 8. října")
        #expect(Format.date(at(2026, 10, 17), .shortWeekdayDayNumericMonth, clock: clock) == "so 17. 10.")
        #expect(Format.date(at(2026, 10, 17), .monthYear, clock: clock) == "říjen 2026")
    }

    @Test("Délky, čísla a odpočet")
    func formats() {
        #expect([59.5, 0, 0.4, 30, 3599, 3600, 5400, 8100.5, 36000].map(Format.duration) ==
            ["1 min", "0 min", "0 min", "30 s", "59 min", "1 h", "1 h 30 min", "2 h 15 min", "10 h"])
        #expect([3.25, 3.35, 2.05, 4].map { Format.decimal($0) } == ["3,3", "3,4", "2,1", "4,0"])
        #expect([12600, 3600, 5940, 0].map(Format.hours) == ["3,5 h", "1 h", "1,7 h", "0 h"])
        #expect([0, 499, 500, 61000, 3725000].map { Format.clock(ms: $0) } == ["00:00", "00:00", "00:01", "01:01", "1:02:05"])
        #expect(Format.count(12345) == "12\u{a0}345")
        #expect(Format.plural(3, "den", "dny", "dní") == "dny")
    }

    @Test("Půl třetí v den jarní změny času neexistuje – web i Mac ji posunou na 3:30")
    func springForward() {
        let day = at(2026, 3, 29, 0)
        #expect(Format.time(clock.atMinutes(day, 150), clock: clock) == "03:30")
    }

    @Test("Půl třetí v den podzimní změny času je dvakrát – web i Mac berou první výskyt (letní čas)")
    func fallBack() {
        let afterChange = 1_792_978_200_000 // 26. 10. 2026 2:30 SEČ
        #expect(clock.addDays(afterChange, -1) == 1_792_888_200_000) // 25. 10. 2:30 SELČ
    }
}
