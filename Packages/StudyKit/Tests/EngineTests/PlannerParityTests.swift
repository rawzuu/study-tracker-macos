import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (Tools/parity/generate-planner.ts) s TZ=Europe/Prague –
// i funkce, které jsou na webu schované v komponentách (rozložení kalendáře, zápis z bloku).
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

@Suite("Kalendář: parita s webem")
struct PlannerParityTests {
    private static let planner: JSONObject = {
        let url = Bundle.module.url(forResource: "planner", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.parse(Data(contentsOf: url)).objectValue!
    }()

    private func cases(_ key: String) -> [JSONObject] {
        (Self.planner.array(key) ?? []).compactMap(\.objectValue)
    }

    /// Položka z kontrolních dat (`kind` jako na webu).
    private func item(_ o: JSONObject) -> CalendarItem {
        let id = o.string("id")!
        let source: CalendarItem.Source = switch o.string("kind") {
        case "plan": .block(id: id)
        case "done": .session(id: id)
        case "live": .live
        default: .lecture(timetableId: "", key: id)
        }
        return CalendarItem(id: id, source: source, subjectId: o.string("subjectId")!, start: o.int("start")!, end: o.int("end")!, title: o.string("title")!)
    }

    @Test("Rozložení překrývajících se položek do sloupců (i se shodným začátkem)")
    func layout() {
        let all = cases("layout")
        #expect(all.count == 400)
        for (n, c) in all.enumerated() {
            let items = c.array("items")!.compactMap(\.objectValue).map(item)
            let lanes = CalendarLayout.lanes(items)
            for row in c.array("lanes")!.compactMap(\.arrayValue) {
                let id = row[0].stringValue!
                let expected = CalendarLayout.Lane(lane: Int(row[1].numberValue!), lanes: Int(row[2].numberValue!))
                #expect(lanes[id] == expected, "#\(n) \(id)")
            }
            #expect(lanes.count == items.count)
        }
    }

    @Test("Položka přes půlnoc se rozdělí do dvou dnů (i ve dnech změny času)")
    func split() {
        for (n, c) in cases("split").enumerated() {
            let parts = CalendarLayout.splitAtMidnight(item(c.object("item")!), clock: clock)
            let expected = c.array("parts")!.compactMap(\.objectValue)
            #expect(parts.count == expected.count, "#\(n)")
            for (p, e) in zip(parts, expected) {
                #expect(p.id == e.string("id") && p.start == e.int("start") && p.end == e.int("end"), "#\(n) \(p.id)")
                let span = e.array("span").map { CalendarItem.Span(start: Int($0[0].numberValue!), end: Int($0[1].numberValue!)) }
                #expect(p.span == span, "#\(n) span")
            }
        }
    }

    @Test("Odškrtnutí bloků podle sezení a „už zapsáno“")
    func match() {
        for (n, c) in cases("match").enumerated() {
            let blocks = c.array("blocks")!.compactMap(\.objectValue).map(PlanBlock.init(raw:))
            let sessions = c.array("sessions")!.compactMap(\.objectValue).map(Session.init(raw:))
            let span = c.object("span")!
            let matched = PlanMatch.blocks(blocks, subjectId: span.string("subjectId")!, start: span.int("start")!, end: span.int("end")!)
            #expect(matched.map(\.id) == c.array("matched")!.compactMap(\.stringValue), "#\(n)")
            #expect(blocks.map { PlanMatch.hasSession(sessions, for: $0) } == c.array("hasSession")!.compactMap(\.boolValue), "#\(n)")
        }
    }

    @Test("Zápis z bloku: začátek a minuty, které do teď proběhly")
    func prefill() {
        for (n, c) in cases("prefill").enumerated() {
            let block = PlanBlock(raw: c.object("block")!)
            let span = PlanMatch.loggedSpan(of: block, now: c.int("now")!)
            #expect(span.start == c.int("start") && span.minutes == c.int("minutes"), "#\(n)")
        }
    }

    @Test("Obnovení z koše vrátí i to, co se smazalo spolu s položkou")
    func restore() throws {
        let all = cases("restore")
        #expect(all.count == 100)
        for (n, c) in all.enumerated() {
            var doc = try AppDocument(normalizing: JSONValue.parse(c.string("input")!))
            doc.restore(CollectionKey(rawValue: c.string("key")!)!, id: c.string("id")!, now: c.int("now")!)
            var touched = JSONObject()
            for key in ["subjects", "sessions", "planBlocks", "exams", "topics"] { touched[key] = doc.raw[key] }
            #expect(JSONValue.object(touched).serialized() == c.string("output"), "#\(n) \(c.string("key")!) \(c.string("id")!)")
        }
    }
}
