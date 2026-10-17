import Core
import Foundation
import Testing
@testable import Engine

// Očekávané hodnoty spočítal kód webu v2.6.7 (`src/lib/time.ts`, `stats.ts`) s TZ=Europe/Prague.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private struct TimeCase: Sendable, CustomTestStringConvertible {
    let p, sod, add1, addm7, sow, som, wd, iso: Int
    let key, time, label: String
    let mod: Double
    var testDescription: String { key }
}

private let timeCases: [TimeCase] = [
    // den před jarní změnou času
    TimeCase(p: 1774695600000, sod: 1774652400000, add1: 1774778400000, addm7: 1774090800000, sow: 1774220400000, som: 1772319600000, wd: 5, iso: 13, key: "2026-03-28", time: "12:00", label: "sobota 28. března", mod: 720),
    // den podzimní změny času (25 h)
    TimeCase(p: 1792884600000, sod: 1792879200000, add1: 1792974600000, addm7: 1792279800000, sow: 1792360800000, som: 1790805600000, wd: 6, iso: 43, key: "2026-10-25", time: "01:30", label: "neděle 25. října", mod: 90),
    TimeCase(p: 1792360740000, sod: 1792274400000, add1: 1792447140000, addm7: 1791755940000, sow: 1791756000000, som: 1790805600000, wd: 6, iso: 42, key: "2026-10-18", time: "23:59", label: "neděle 18. října", mod: 1439),
    // přelom roku, 53. týden
    TimeCase(p: 1798786800000, sod: 1798758000000, add1: 1798873200000, addm7: 1798182000000, sow: 1798412400000, som: 1798758000000, wd: 4, iso: 53, key: "2027-01-01", time: "08:00", label: "pátek 1. ledna", mod: 480),
    TimeCase(p: 1798750800000, sod: 1798671600000, add1: 1798837200000, addm7: 1798146000000, sow: 1798412400000, som: 1796079600000, wd: 3, iso: 53, key: "2026-12-31", time: "22:00", label: "čtvrtek 31. prosince", mod: 1320),
    TimeCase(p: 1609664400000, sod: 1609628400000, add1: 1609750800000, addm7: 1609059600000, sow: 1609110000000, som: 1609455600000, wd: 6, iso: 53, key: "2021-01-03", time: "10:00", label: "neděle 3. ledna", mod: 600),
]

/// Okamžik v pražském čase.
private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!)
}

private func session(_ start: Int, _ sec: Int, focus: Int? = nil, subject: String = "a") -> Session {
    var raw: JSONObject = ["id": .string("\(start)"), "subjectId": .string(subject), "start": .number(Double(start)), "end": .number(Double(start + sec * 1000)), "durationSec": .number(Double(sec))]
    if let focus { raw["focus"] = .number(Double(focus)) }
    return Session(raw: raw)
}

@Suite("Čas a souhrny jako na webu")
struct TimeAndStatsTests {
    @Test("Kalendář v místním čase (i přes změnu času)", arguments: timeCases)
    fileprivate func calendar(_ c: TimeCase) {
        #expect(clock.dayKey(c.p) == c.key)
        #expect(clock.startOfDay(c.p) == c.sod)
        #expect(clock.addDays(c.p, 1) == c.add1)
        #expect(clock.addDays(c.p, -7) == c.addm7)
        #expect(clock.startOfWeek(c.p) == c.sow)
        #expect(clock.startOfMonth(c.p) == c.som)
        #expect(clock.weekdayIndex(c.p) == c.wd)
        #expect(clock.isoWeek(c.p) == c.iso)
        #expect(clock.minutesOfDay(c.p) == c.mod)
        #expect(clock.parseDayKey(c.key) == c.sod)
        #expect(Format.time(c.p, clock: clock) == c.time)
        #expect(Format.longDay(c.p, clock: clock) == c.label)
    }

    @Test("Dnes, včera, zítra")
    func dayLabel() {
        let now = at(2026, 10, 17, 12)
        #expect(Format.dayLabel(at(2026, 10, 17, 1), now: now, clock: clock) == "Dnes")
        #expect(Format.dayLabel(at(2026, 10, 16, 23), now: now, clock: clock) == "Včera")
        #expect(Format.dayLabel(at(2026, 10, 18, 23), now: now, clock: clock) == "Zítra")
        #expect(Format.dayLabel(at(2026, 10, 8), now: now, clock: clock) == "čtvrtek 8. října")
        #expect(Format.capitalized("čtvrtek 8. října") == "Čtvrtek 8. října")
        #expect(Format.shortDay(at(2026, 10, 17), clock: clock) == "so 17. 10.")
    }

    @Test("Délky, čísla a odpočet")
    func formats() {
        #expect([59.5, 0, 0.4, 30, 3599, 3600, 5400, 8100.5, 36000].map(Format.duration) ==
            ["1 min", "0 min", "0 min", "30 s", "59 min", "1 h", "1 h 30 min", "2 h 15 min", "10 h"])
        #expect([3.25, 3.35, 2.05, 4].map { Format.decimal($0) } == ["3,3", "3,4", "2,1", "4,0"])
        #expect([12600, 3600, 5940, 0].map(Format.hours) == ["3,5 h", "1 h", "1,7 h", "0 h"])
        #expect([0, 499, 500, 61000, 3725000].map { Format.clock(ms: $0) } == ["00:00", "00:00", "00:01", "01:01", "1:02:05"])
        #expect(Format.plural(1, "den", "dny", "dní") == "den")
        #expect(Format.plural(3, "den", "dny", "dní") == "dny")
        #expect(Format.plural(5, "den", "dny", "dní") == "dní")
        #expect(Format.plural(0, "den", "dny", "dní") == "dní")
    }

    @Test("Série s dny volna a minimem minut")
    func streaks() {
        let list = [
            session(at(2026, 10, 5), 3600, focus: 4), session(at(2026, 10, 6), 600), session(at(2026, 10, 8), 1200, focus: 0),
            session(at(2026, 10, 9), 1800, focus: 5), session(at(2026, 10, 10), 100), session(at(2026, 10, 12), 2000, focus: 3),
            session(at(2026, 10, 13), 2000), session(at(2026, 10, 15), 2000), session(at(2026, 10, 17, 8), 2000),
        ]
        let now = at(2026, 10, 17, 20)
        let cases: [(rest: Int, min: Int, current: Int, best: Int)] = [(0, 0, 1, 3), (1, 0, 1, 5), (2, 0, 9, 9), (0, 20, 1, 2), (1, 20, 1, 3)]
        for c in cases {
            let r = Stats.streaks(list, restDays: c.rest, minMin: c.min, now: now, clock: clock)
            #expect(r.current == c.current && r.best == c.best, "volno \(c.rest), min \(c.min)")
        }
        #expect(Stats.avgFocus(list) == 4)
        #expect(Stats.streaks([], now: now, clock: clock) == (0, 0))
    }

    @Test("Součty po dnech, předmětech a v intervalu")
    func totals() {
        let list = [session(at(2026, 10, 5, 9), 600, subject: "a"), session(at(2026, 10, 5, 23), 1200, subject: "b"), session(at(2026, 10, 6, 0), 300, subject: "a")]
        #expect(Stats.byDay(list, clock: clock) == ["2026-10-05": 1800, "2026-10-06": 300])
        #expect(Stats.bySubject(list) == ["a": 900, "b": 1200])
        #expect(Stats.totalSec(Stats.inRange(list, from: at(2026, 10, 5, 0), to: at(2026, 10, 6, 0))) == 1800)
    }

    @Test("Témata k zopakování")
    func dueTopics() {
        let now = at(2026, 10, 17, 12)
        let dayEnd = clock.addDays(clock.startOfDay(now), 1)
        let due = Topic(raw: ["id": "t1", "nextReviewAt": .number(Double(at(2026, 10, 15)))])
        let later = Topic(raw: ["id": "t2", "nextReviewAt": .number(Double(at(2026, 10, 18, 1)))])
        let mastered = Topic(raw: ["id": "t3", "nextReviewAt": .number(Double(at(2026, 10, 1))), "mastered": true])
        #expect(due.isDue(before: dayEnd) && !later.isDue(before: dayEnd) && !mastered.isDue(before: dayEnd))
        #expect(due.overdueDays(now: now, clock: clock) == 2)
        #expect(later.overdueDays(now: now, clock: clock) == -1)
    }
}
