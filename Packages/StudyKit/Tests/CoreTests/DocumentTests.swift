import Foundation
import Testing
@testable import Core

private func doc(_ json: String) throws -> AppDocument {
    try AppDocument(normalizing: JSONValue.parse(json))
}

@Suite("Dopředná kompatibilita") struct ForwardCompatibilityTests {
    @Test("Neznámá kolekce se slučuje po záznamech, ne celá z jedné strany")
    func unknownCollectionMergesPerEntity() throws {
        let local = try doc(#"{"notes":[{"id":"a","updatedAt":1,"v":"stará"},{"id":"m","updatedAt":5,"v":"jen Mac"}]}"#)
        let remote = try doc(#"{"notes":[{"id":"a","updatedAt":2,"v":"nová"},{"id":"w","updatedAt":3,"v":"jen web"}]}"#)
        let merged = Merge.mergeData(local: local, remote: remote).raw.array("notes") ?? []
        let values = merged.compactMap { $0.objectValue?.string("v") }
        #expect(Set(values) == ["nová", "jen Mac", "jen web"])
    }

    @Test("Neznámé pole bere ze vzdálené strany (tahle verze ho nikdy nemění)")
    func unknownScalarPrefersRemote() throws {
        let local = try doc(#"{"futureFlag":"stará","localOnly":1}"#)
        let remote = try doc(#"{"futureFlag":"nová"}"#)
        let merged = Merge.mergeData(local: local, remote: remote).raw
        #expect(merged.string("futureFlag") == "nová")
        #expect(merged.number("localOnly") == 1)
    }

    @Test("Úprava přes typovaný pohled zachová neznámá pole i pořadí klíčů")
    func lensKeepsUnknownFields() throws {
        let text = #"{"id":"s1","futureField":{"x":[1,2]},"note":"a","createdAt":1,"updatedAt":1}"#
        var session = Session(raw: try #require(JSONValue.parse(text).objectValue))
        session.note = "b"
        #expect(JSONValue.object(session.raw).serialized() == #"{"id":"s1","futureField":{"x":[1,2]},"note":"b","createdAt":1,"updatedAt":1}"#)
    }

    @Test("Neznámé nastavení přežije úpravu nastavení")
    func settingsKeepUnknownKeys() throws {
        var d = try doc(#"{"settings":{"updatedAt":1,"futureSetting":{"a":1}}}"#)
        d.updateSettings(now: 50) { $0.dailyGoalMin = 90 }
        #expect(d.settings.raw.object("futureSetting") == ["a": 1])
        #expect(d.settings.dailyGoalMin == 90)
        #expect(d.settings.updatedAt == 50)
    }
}

@Suite("Zápis záznamů jako store.tsx") struct WriteTests {
    @Test("Nový záznam dostane createdAt i updatedAt")
    func upsertNew() {
        var d = AppDocument.empty
        var s = Subject(raw: ["id": "x"])
        s.name = "Matematika"
        d.upsert(s, now: 100)
        let saved = d.record(Subject.self, id: "x")
        #expect(saved?.createdAt == 100)
        #expect(saved?.updatedAt == 100)
        #expect(saved?.name == "Matematika")
    }

    @Test("Úprava zachová createdAt a pole, která nová verze neposlala")
    func upsertExisting() throws {
        var d = try doc(##"{"subjects":[{"id":"x","name":"A","color":"#fff","futureField":true,"createdAt":1,"updatedAt":1}]}"##)
        d.upsert(Subject(raw: ["id": "x", "name": "B"]), now: 9)
        let saved = try #require(d.record(Subject.self, id: "x"))
        #expect(saved.createdAt == 1)
        #expect(saved.updatedAt == 9)
        #expect(saved.name == "B")
        #expect(saved.color == "#fff")
        #expect(saved.raw.bool("futureField") == true)
    }

    @Test("Smazání je měkké a posune updatedAt")
    func softDelete() throws {
        var d = try doc(#"{"sessions":[{"id":"s","createdAt":1,"updatedAt":1}]}"#)
        d.remove(.sessions, id: "s", now: 7)
        let s = try #require(d.record(Session.self, id: "s"))
        #expect(s.isDeleted)
        #expect(s.deletedAt == 7)
        #expect(s.updatedAt == 7)
        #expect(d.alive(Session.self).isEmpty)
    }

    @Test("Nová id mají tvar crypto.randomUUID()")
    func newIDShape() {
        let id = Session.newID()
        #expect(id.count == 36)
        #expect(id == id.lowercased())
    }
}

/// Kontrola na skutečných datech – běží jen lokálně, data nikdy nejsou v repu.
///   ST_REAL_DATA=…/data.json ST_REAL_EXPECTED=…/expected.json swift test --filter RealData
@Suite("Skutečná data (jen lokálně)") struct RealDataTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ST_REAL_DATA"] != nil))
    func realDataRoundTrip() throws {
        let env = ProcessInfo.processInfo.environment
        let input = try Data(contentsOf: URL(fileURLWithPath: env["ST_REAL_DATA"]!))
        let expected = try String(contentsOf: URL(fileURLWithPath: env["ST_REAL_EXPECTED"]!), encoding: .utf8)
        let d = try AppDocument(parsing: input)
        #expect(Merge.serialize(d) == expected)
        #expect(Merge.serialize(Merge.mergeData(local: d, remote: d)) == expected)
        #expect(!Merge.hasNewer(local: d, incoming: d))
    }
}
