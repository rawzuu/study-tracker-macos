import Core
import Foundation
import Testing
@testable import Engine

// Čitelné ukázky; úplné srovnání s webem je v TimetableParityTests.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi))!)
}

@Suite("Rozvrh – ukázky")
struct TimetableTests {
    private let ics = """
        BEGIN:VCALENDAR
        X-WR-CALNAME:Rozvrh\\, LS
        BEGIN:VEVENT
        UID:a
        SUMMARY:Anatomie  –  přednáška
        LOCATION:Posluchárna A
        DTSTART;TZID=Europe/Prague:20261019T091500
        DTEND;TZID=Europe/Prague:20261019T104500
        RRULE:FREQ=WEEKLY;COUNT=3
        EXDATE;TZID=Europe/Prague:20261026T091500
        END:VEVENT
        BEGIN:VEVENT
        UID:a
        RECURRENCE-ID;TZID=Europe/Prague:20261102T091500
        SUMMARY:Anatomie – náhrada
        DTSTART;TZID=Europe/Prague:20261103T130000
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Zápočtový týden
        DTSTART;VALUE=DATE:20261214
        END:VEVENT
        END:VCALENDAR
        """

    @Test("Opakování, výjimka a přesunutý termín (přes změnu času)")
    func parse() throws {
        let r = try ICal.parse(ics, clock: clock)
        #expect(r.name == "Rozvrh, LS" && r.skippedAllDay == 1)
        #expect(r.events.map(\.start) == [at(10, 19, 9, 15), at(11, 3, 13)])
        #expect(r.events[0].series == "Anatomie – přednáška" && r.events[0].key == "Anatomie – přednáška|\(at(10, 19, 9, 15))")
        #expect(r.events[1].title == "Anatomie – náhrada" && r.events[1].end - r.events[1].start == 90 * StudyClock.minute)
        #expect(throws: ICal.ParseError.notCalendar) { try ICal.parse("BEGIN:VEVENT", clock: clock) }
    }

    @Test("Number() z JavaScriptu v pravidlech opakování")
    func jsNumber() {
        #expect(ICal.jsNumber("0x3") == 3 && ICal.jsNumber(" 2 ") == 2 && ICal.jsNumber("1e1") == 10 && ICal.jsNumber("") == 0)
        #expect(ICal.jsNumber("abc") == nil && ICal.jsNumber("inf") == nil && ICal.jsNumber("Infinity") == .infinity)
    }

    @Test("Obří nebo nekonečný INTERVAL dá jen první výskyt a nespadne", arguments: ["Infinity", "1e20", "100000"])
    func hugeInterval(_ interval: String) throws {
        for freq in ["DAILY", "WEEKLY"] {
            let ics = """
                BEGIN:VCALENDAR
                BEGIN:VEVENT
                SUMMARY:Anatomie
                DTSTART;TZID=Europe/Prague:20261019T091500
                DTEND;TZID=Europe/Prague:20261019T104500
                RRULE:FREQ=\(freq);INTERVAL=\(interval)
                END:VEVENT
                END:VCALENDAR
                """
            #expect(try ICal.parse(ics, clock: clock).events.map(\.start) == [at(10, 19, 9, 15)])
        }
    }

    @Test("Nový rozvrh má klíče jako na webu; nová verze zachová proběhlé hodiny a skryté řady")
    func replace() {
        func event(_ series: String, _ start: Int) -> TimetableEvent {
            TimetableEvent(raw: ["key": .string("\(series)|\(start)"), "series": .string(series), "title": .string(series), "location": "",
                                 "start": .number(Double(start)), "end": .number(Double(start + 90 * StudyClock.minute))])
        }
        var tt = Timetables.new(name: "  ", events: [event("A", at(10, 12, 9)), event("A", at(10, 19, 9)), event("B", at(10, 20, 9))], now: 1)
        #expect(Array(tt.raw.keys) == ["id", "name", "importedAt", "events", "hiddenSeries", "skipped"] && tt.name == "Rozvrh")
        tt.hiddenSeries = ["A", "B"]
        tt.skipped = ["A|\(at(10, 19, 9))"]
        let now = at(10, 15, 12)
        let next = [event("A", at(10, 19, 9)), event("C", at(10, 21, 9))]
        let diff = Timetables.diff(old: tt.events, next: next, now: now)
        #expect(diff == Timetables.Diff(added: 1, removed: 1, unchanged: 1, addedSeries: ["C"], removedSeries: ["B"]))
        let replaced = Timetables.replacingEvents(tt, with: next, now: now)
        #expect(replaced.events.map(\.key) == ["A|\(at(10, 12, 9))", "A|\(at(10, 19, 9))", "C|\(at(10, 21, 9))"])
        #expect(replaced.hiddenSeries == ["A"] && replaced.skipped == ["A|\(at(10, 19, 9))"] && replaced.importedAt == now)
    }
}
