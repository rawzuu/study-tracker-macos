import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (`src/lib/ical.ts`, `src/lib/timetable.ts`) s TZ=Europe/Prague.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private func fixture(_ name: String) -> [JSONObject] {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return (try! JSONValue.parse(Data(contentsOf: url))).arrayValue!.compactMap(\.objectValue)
}

@Suite("Rozvrh: parita s webem")
struct TimetableParityTests {
    @Test("Čtení .ics: pásma, změny času, opakování, výjimky, přesuny, zalomené řádky")
    func parse() {
        let cases = fixture("ical")
        #expect(cases.count > 120)
        for (n, c) in cases.enumerated() {
            let text = c.string("text")!
            do {
                let r = try ICal.parse(text, clock: clock)
                #expect(c.string("error") == nil, "#\(n) web hlásí chybu: \(c.string("error") ?? "")")
                #expect(r.name == c.string("name"), "#\(n) název")
                #expect(r.skippedAllDay == c.int("skippedAllDay"), "#\(n) celodenní")
                let expected = c.array("events") ?? []
                #expect(r.events.count == expected.count, "#\(n) počet \(r.events.count) vs \(expected.count)")
                for (i, (got, want)) in zip(r.events, expected.compactMap(\.objectValue)).enumerated() {
                    #expect(JSONValue.object(got.raw).serialized() == JSONValue.object(want).serialized(), "#\(n)/\(i)")
                }
            } catch {
                #expect(error.localizedDescription == c.string("error"), "#\(n)")
            }
        }
    }

    @Test("Rozvrh: hodiny v týdnu, náhled změn, nová verze a přehled řad")
    func timetables() {
        let cases = fixture("timetables")
        #expect(cases.count == 60)
        for (n, c) in cases.enumerated() {
            let tt = Timetable(raw: c.object("tt")!)
            let next = c.array("next")!.compactMap(\.objectValue).map(TimetableEvent.init(raw:))
            let now = c.int("now")!

            var doc = AppDocument.empty
            var second = tt
            second.id = "tt2"
            second.events = Array(tt.events.prefix(2))
            second.hiddenSeries = []
            second.skipped = []
            doc.upsert(c.bool("deleted") == true ? [tt] : [tt, second], now: 1)
            if c.bool("deleted") == true { doc.remove(.timetables, id: "tt", now: 5) }
            let lectures = Timetables.lectures(doc, from: c.int("from")!, to: c.int("to")!).map { "\($0.timetableId):\($0.event.key)" }
            #expect(lectures == c.array("lectures")!.compactMap(\.stringValue), "#\(n) hodiny")

            let d = c.object("diff")!
            let diff = Timetables.diff(old: tt.events, next: next, now: now)
            #expect(diff == Timetables.Diff(added: d.int("added")!, removed: d.int("removed")!, unchanged: d.int("unchanged")!,
                                            addedSeries: d.array("addedSeries")!.compactMap(\.stringValue),
                                            removedSeries: d.array("removedSeries")!.compactMap(\.stringValue)), "#\(n) změny")

            #expect(JSONValue.object(Timetables.replacingEvents(tt, with: next, now: now).raw).serialized() == c.string("replaced"), "#\(n) nová verze")

            let series = Timetables.series(of: tt, now: now, clock: clock).map {
                JSONValue.object(["series": .string($0.series), "count": .number(Double($0.count)), "upcoming": .number(Double($0.upcoming)),
                                  "when": .string($0.when), "hidden": .bool($0.hidden)]).serialized()
            }
            #expect(series == c.array("series")!.map { $0.serialized() }, "#\(n) řady")
        }
    }
}
