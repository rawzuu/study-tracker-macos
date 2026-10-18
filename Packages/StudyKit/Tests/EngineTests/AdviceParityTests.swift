import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (`src/lib/recommend.ts`, `src/lib/dayplan.ts`) s TZ=Europe/Prague
// na náhodných datech bez témat a s vypnutým opakováním po přednášce (`Tools/parity/generate-advice.ts`).
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private let advice: JSONObject = {
    let url = Bundle.module.url(forResource: "advice", withExtension: "json", subdirectory: "Fixtures")!
    return (try! JSONValue.parse(Data(contentsOf: url))).objectValue!
}()

private func objects(_ o: JSONObject, _ key: String) -> [JSONObject] { (o.array(key) ?? []).compactMap(\.objectValue) }
private func strings(_ o: JSONObject, _ key: String) -> [String] { (o.array(key) ?? []).compactMap(\.stringValue) }

/// Texty, které Mac píše jinak než web (záměrně): česky správné tvary a hláška bez opakování.
private func macWording(_ web: String?) -> String? {
    guard let web else { return nil }
    if let m = web.wholeMatch(of: /Anki: ([0-9]+) karet/), let n = Int(m.1) {
        return "Anki: \(n) \(Format.plural(n, "karta", "karty", "karet"))"
    }
    if web == "V tuhle denní dobu ti soustředění obvykle jde hůř – vhodné na opakování a kartičky." {
        return "V tuhle denní dobu ti soustředění obvykle jde hůř – vhodné spíš na kartičky a lehčí látku."
    }
    return web
}

private func close(_ a: Double, _ b: Double?) -> Bool {
    guard let b else { return false }
    return abs(a - b) <= 1e-12 * max(1, abs(b))
}

private func describe(_ i: DayPlanItem) -> String {
    "\(i.key)|\(i.subjectId)|\(i.title)|\(i.minutes)|\(i.start)|\(i.activity.rawValue)|\(i.reasons.joined(separator: "; "))|\(i.include)|\(i.carry?.id ?? "-")"
}

private func describe(_ o: JSONObject) -> String {
    "\(o.string("key")!)|\(o.string("subjectId")!)|\(o.string("title")!)|\(o.int("minutes")!)|\(o.int("start")!)|\(o.string("activity")!)|"
        + "\(strings(o, "reasons").joined(separator: "; "))|\(o.bool("include")!)|\(o.string("carry") ?? "-")"
}

@Suite("Co teď? a ranní plán: parita s webem")
struct AdviceParityTests {
    let datasets = objects(advice, "datasets").map { ds in
        (doc: try! AppDocument(normalizing: .object(ds.object("data")!)), cases: objects(ds, "cases"))
    }

    @Test("Doporučení: skóre, signály, činnost, délka bloku, důvody i pořadí")
    func recommendations() {
        #expect(datasets.count == 18)
        var compared = 0
        for (n, ds) in datasets.enumerated() {
            for (k, c) in ds.cases.enumerated() {
                let now = c.int("now")!
                let at = "#\(n)/\(k)"
                let recs = Recommender(document: ds.doc, now: now, clock: clock).recommend()
                let want = objects(c, "recs")
                #expect(recs.map(\.key) == want.map { $0.string("key")! }, "\(at) pořadí")
                for (got, w) in zip(recs, want) {
                    #expect(got.subjectId == w.string("subjectId"), "\(at) předmět")
                    #expect(got.activity.rawValue == w.string("activity"), "\(at) činnost")
                    #expect(got.title == macWording(w.string("title")), "\(at) název")
                    #expect(got.topic == w.string("topic"), "\(at) téma")
                    #expect(got.minutes == w.int("minutes"), "\(at) minuty")
                    #expect(got.modeId == w.string("modeId"), "\(at) režim")
                    #expect(got.planBlockId == w.string("planBlockId"), "\(at) blok")
                    #expect(close(got.score, w.number("score")), "\(at) skóre \(got.score) vs \(w.number("score") ?? .nan)")
                    let s = w.object("signals")!
                    for (name, value) in [("E", got.signals.E), ("R", got.signals.R), ("G", got.signals.G), ("N", got.signals.N), ("P", got.signals.P), ("X", got.signals.X)] {
                        #expect(close(value, s.number(name)), "\(at) signál \(name)")
                    }
                    #expect(got.reasons == strings(w, "reasons").map { macWording($0)! }, "\(at) důvody")
                    compared += 1
                }

                let sessions = ds.doc.alive(Session.self)
                #expect(Recommender.contextNote(ds.doc, now: now, clock: clock) == macWording(c.string("note")), "\(at) hláška")
                #expect(close(Recommender.weekShare(sessions, now: now, clock: clock), c.number("share")), "\(at) část týdne")
                #expect(Recommender.lowFocusNow(sessions, now: now, clock: clock) == c.bool("lowFocus"), "\(at) slabší doba")
                let recent = sessions.filter { $0.start > now - 60 * StudyClock.day && $0.mode != "anki" }
                let peak = Stats.focusWindow(recent, clock: clock)
                let wantPeak = c.object("peak").map { [$0.int("from")!, $0.int("to")!] }
                #expect(peak.map { [$0.from, $0.to] } == wantPeak, "\(at) nejsilnější doba")
                let b = DayPlan.dayBounds(ds.doc.settings, now: now, clock: clock)
                let wb = c.object("bounds")!
                let wantBounds: [Int] = [wb.int("day")!, wb.int("from")!, wb.int("to")!]
                #expect([b.day, b.from, b.to] == wantBounds, "\(at) rozmezí dne")
            }
        }
        #expect(compared > 300)
    }

    @Test("Ranní plán: návrh, rozmístění a nové rozmístění po úpravách")
    func dayPlan() {
        var items = 0
        for (n, ds) in datasets.enumerated() {
            for (k, c) in ds.cases.enumerated() {
                let now = c.int("now")!
                let at = "#\(n)/\(k)"
                let proposal = DayPlan.propose(ds.doc, now: now, extra: c.int("extra")!, clock: clock)
                #expect(proposal.map(describe) == objects(c, "items").map(describe), "\(at) návrh")

                let edit = c.object("edit")!
                let resize = edit.object("resize")
                let edited = proposal.filter { $0.key != edit.string("drop") }.map { i in
                    var i = i
                    if i.key == resize?.string("key") { i.minutes = resize!.int("minutes")! }
                    if i.key == edit.string("uncheck") { i.include = false }
                    i.start = 0
                    return i
                }
                let reflow = DayPlan.place(ds.doc, items: edited, now: now, clock: clock)
                #expect(reflow.map(describe) == objects(c, "reflow").map(describe), "\(at) po úpravě")
                items += proposal.count
            }
        }
        #expect(items > 300)
    }

    @Test("Volné místo dne a pauza po bloku")
    func slots() {
        let cases = objects(advice, "findSlot")
        #expect(cases.count == 300)
        for (n, c) in cases.enumerated() {
            let busy = (c.array("busy") ?? []).compactMap(\.arrayValue).map { BusyInterval(start: Int($0[0].numberValue!), end: Int($0[1].numberValue!)) }
            let slot = DayPlan.findSlot(busy, from: c.int("from")!, to: c.int("to")!, minutes: c.int("minutes")!)
            #expect(slot == c.int("slot"), "#\(n)")
        }
        for pair in (advice.array("breaks") ?? []).compactMap(\.arrayValue) {
            let minutes = Int(pair[0].numberValue!)
            #expect(DayPlan.breakAfter(minutes) == Int(pair[1].numberValue!), "\(minutes)")
        }
    }
}
