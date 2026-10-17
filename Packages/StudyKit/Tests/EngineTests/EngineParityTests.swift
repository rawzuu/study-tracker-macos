import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (Tools/parity/generate-engine.ts) s TZ=Europe/Prague.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

/// Dvojice `[vstup, výsledek]` z kontrolních dat.
private struct Pair: Decodable {
    let input: Int
    let output: Int

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        input = try c.decode(Int.self)
        output = try c.decode(Int.self)
    }
}

private struct CalendarCase: Decodable {
    let t: Int
    let dayKey: String
    let startOfDay: Int
    let parsed: Int
    let addDays: [Pair]
    let minutesOfDay: Double
    let atMinutes: [Pair]
    let startOfWeek: Int
    let startOfMonth: Int
    let weekday: Int
    let isoWeek: Int
    let time: String
    let dates: [String: String]
    let now: Int
    let dayLabel: String
    let capitalized: String
}

private struct Formats: Decodable {
    struct Seconds: Decodable { let sec: Double; let text: String }
    struct Decimal: Decodable { let n: Double; let digits: Int; let text: String }
    struct Millis: Decodable { let ms: Int; let text: String }
    struct Count: Decodable { let n: Int; let text: String }
    let durations: [Seconds]
    let decimals: [Decimal]
    let hours: [Seconds]
    let clocks: [Millis]
    let counts: [Count]
    let plurals: [Count]
}

private struct StatsCase: Decodable {
    struct Row: Decodable {
        let id: String
        let subjectId: String
        let start: Int
        let end: Int
        let durationSec: Int
        let focus: Int?
    }
    struct Rules: Decodable { let restDays: Int; let minMin: Int }
    struct Streaks: Decodable { let current: Int; let best: Int }
    let sessions: [Row]
    let rules: Rules
    let now: Int
    let from: Int
    let to: Int
    let inRange: [String]
    let totalSec: Int
    let byDay: [String: Int]
    let bySubject: [String: Int]
    let streakDays: [String]
    let streaks: Streaks
    let avgFocus: Double?

    var records: [Session] {
        sessions.map { r in
            var raw: JSONObject = [
                "id": .string(r.id), "subjectId": .string(r.subjectId), "start": .number(Double(r.start)),
                "end": .number(Double(r.end)), "durationSec": .number(Double(r.durationSec)),
            ]
            if let focus = r.focus { raw["focus"] = .number(Double(focus)) }
            return Session(raw: raw)
        }
    }
}

@Suite("Engine: parita s webem")
struct EngineParityTests {
    @Test("Kalendář v místním čase (změny času, přestupné roky, 53. týden)")
    func calendar() throws {
        let cases = try Fixture.load("calendar", as: [CalendarCase].self)
        #expect(cases.count > 400)
        for c in cases {
            let t = c.t
            #expect(clock.dayKey(t) == c.dayKey, "dayKey \(t)")
            #expect(clock.startOfDay(t) == c.startOfDay, "startOfDay \(t)")
            #expect(clock.parseDayKey(c.dayKey) == c.parsed, "parseDayKey \(c.dayKey)")
            for p in c.addDays { #expect(clock.addDays(t, p.input) == p.output, "addDays \(t) \(p.input)") }
            #expect(clock.minutesOfDay(t) == c.minutesOfDay, "minutesOfDay \(t)")
            for p in c.atMinutes { #expect(clock.atMinutes(c.startOfDay, p.input) == p.output, "atMinutes \(c.dayKey) \(p.input)") }
            #expect(clock.startOfWeek(t) == c.startOfWeek, "startOfWeek \(t)")
            #expect(clock.startOfMonth(t) == c.startOfMonth, "startOfMonth \(t)")
            #expect(clock.weekdayIndex(t) == c.weekday, "weekday \(t)")
            #expect(clock.isoWeek(t) == c.isoWeek, "isoWeek \(t)")
            #expect(Format.time(t, clock: clock) == c.time, "time \(t)")
            #expect(Set(c.dates.keys) == Set(Format.DateStyle.allCases.map(\.rawValue)))
            for style in Format.DateStyle.allCases {
                #expect(Format.date(t, style, clock: clock) == c.dates[style.rawValue], "\(style) \(t)")
            }
            let label = Format.dayLabel(t, now: c.now, clock: clock)
            #expect(label == c.dayLabel, "dayLabel \(t) / \(c.now)")
            #expect(Format.capitalized(label) == c.capitalized)
        }
    }

    @Test("Délky, desetinná čísla, hodiny, odpočet, počty a sklonování")
    func formats() throws {
        let f = try Fixture.load("formats", as: Formats.self)
        for c in f.durations { #expect(Format.duration(c.sec) == c.text, "duration \(c.sec)") }
        for c in f.decimals { #expect(Format.decimal(c.n, digits: c.digits) == c.text, "decimal \(c.n) / \(c.digits)") }
        for c in f.hours { #expect(Format.hours(Int(c.sec)) == c.text, "hours \(c.sec)") }
        for c in f.clocks { #expect(Format.clock(ms: c.ms) == c.text, "clock \(c.ms)") }
        for c in f.counts { #expect(Format.count(c.n) == c.text, "count \(c.n)") }
        for c in f.plurals { #expect(Format.plural(c.n, "den", "dny", "dní") == c.text, "plural \(c.n)") }
    }

    @Test("Normalizace názvů pro hledání předmětu")
    func names() throws {
        struct NameCase: Decodable { let s: String; let norm: String }
        for c in try Fixture.load("names", as: [NameCase].self) {
            #expect(normalizedName(c.s) == c.norm, "\(c.s)")
        }
    }

    @Test("Souhrny: interval, po dnech, po předmětech, série a soustředění")
    func stats() throws {
        let cases = try Fixture.load("stats", as: [StatsCase].self)
        #expect(cases.count >= 150)
        for (i, c) in cases.enumerated() {
            let list = c.records
            #expect(Stats.inRange(list, from: c.from, to: c.to).map(\.id) == c.inRange, "inRange #\(i)")
            #expect(Stats.totalSec(list) == c.totalSec, "totalSec #\(i)")
            #expect(Stats.byDay(list, clock: clock) == c.byDay, "byDay #\(i)")
            #expect(Stats.bySubject(list) == c.bySubject, "bySubject #\(i)")
            #expect(Stats.streakDays(list, minMin: c.rules.minMin, clock: clock).sorted() == c.streakDays, "streakDays #\(i)")
            let s = Stats.streaks(list, restDays: c.rules.restDays, minMin: c.rules.minMin, now: c.now, clock: clock)
            #expect(s.current == c.streaks.current && s.best == c.streaks.best, "streaks #\(i) \(c.rules)")
            #expect(Stats.avgFocus(list) == c.avgFocus, "avgFocus #\(i)")
        }
    }
}
