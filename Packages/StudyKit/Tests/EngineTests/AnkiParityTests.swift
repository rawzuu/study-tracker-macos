import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (`runAnkiSync`, `clusterReviews`) s podvrženou Anki – Tools/parity/generate-anki.ts.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

@Suite("Čas z Anki: parita s webem")
struct AnkiParityTests {
    private static let fixture: JSONObject = {
        let url = Bundle.module.url(forResource: "anki", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.parse(Data(contentsOf: url)).objectValue!
    }()

    @Test("Stav balíčků, předmět Anki, sezení a smazání jako na webu")
    func changes() throws {
        let cases = Self.fixture.array("cases")!.compactMap(\.objectValue)
        #expect(cases.count == 160)
        var compared = 0
        for (n, c) in cases.enumerated() {
            var raw = AppDocument.empty.raw
            for (key, value) in c.object("data")! where key != "settings" { raw[key] = value }
            var settings = Schema.defaultSettings
            settings["anki"] = c.object("data")!.object("settings")!["anki"]
            raw["settings"] = .object(settings)
            let doc = try AppDocument(normalizing: .object(raw))
            let now = c.int("now")!
            let since = AnkiImport.since(doc, fullHistory: c.bool("full")!, now: now, clock: clock)
            #expect(AnkiImport.fetchFrom(since: since, clock: clock) == c.int("since"), "#\(n) od kdy")

            let answer = c.object("answer")!
            let fetch = AnkiImport.Fetch(
                decks: answer.array("decks")!.compactMap(\.objectValue).map(AnkiDeckStat.init(raw:)),
                reviewedToday: answer.int("reviewedToday")!,
                reviews: answer.array("reviews")!.compactMap(\.objectValue).map { .init(deck: $0.string("deck")!, time: $0.int("time")!, durationMs: $0.int("durationMs")!) },
                reviewsFetched: answer.bool("reviewsFetched")!
            )
            let got = AnkiImport.changes(doc, fetch: fetch, since: since, now: now, clock: clock)
            var want = AnkiImport.Changes()
            for op in c.array("ops")!.compactMap(\.objectValue) {
                switch (op.string("op")!, op.string("key")!) {
                case ("upsert", "anki"): want.snapshot = AnkiSnapshot(raw: op.object("value")!)
                case ("upsert", "subjects"): want.subject = Subject(raw: op.object("value")!)
                case ("upsertMany", "sessions"): want.sessions = op.array("value")!.compactMap(\.objectValue).map(Session.init(raw:))
                case ("remove", "sessions"): want.remove.append(op.string("value")!)
                default: Issue.record("#\(n): neznámá změna \(op)")
                }
            }
            #expect(got.snapshot?.raw == want.snapshot?.raw, "#\(n) stav balíčků")
            #expect(got.subject?.raw == want.subject?.raw, "#\(n) předmět Anki")
            #expect(got.sessions.map(\.raw) == want.sessions.map(\.raw), "#\(n) sezení")
            #expect(got.remove == want.remove, "#\(n) smazání")
            compared += want.sessions.count + want.remove.count
        }
        #expect(compared > 200)
    }

    @Test("Id sezení: úseky mimo písmena a číslice → _ (jako regulární výraz s příznakem u)")
    func ids() {
        for c in Self.fixture.array("ids")!.compactMap(\.objectValue) {
            #expect(AnkiImport.sessionId(deck: c.string("deck")!, start: 1) == c.string("id"), "\(c.string("deck")!)")
        }
    }
}
