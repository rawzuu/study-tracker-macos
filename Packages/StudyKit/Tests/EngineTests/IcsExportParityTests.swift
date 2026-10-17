import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (`ics.ts`, `calendarFeed.ts`) s TZ=Europe/Prague a pevným Date.now.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

@Suite("Export do kalendáře: parita s webem")
struct IcsExportParityTests {
    private static let fixture: JSONObject = {
        let url = Bundle.module.url(forResource: "ics", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.parse(Data(contentsOf: url)).objectValue!
    }()

    private func records<R: EntityRecord>(_ c: JSONObject, _ key: String) -> [R] {
        (c.array(key) ?? []).compactMap(\.objectValue).map(R.init(raw:))
    }

    @Test("Soubor .ics: UTC, zkoušky s časem i bez, escapování, zalomení po bajtech, připomenutí")
    func build() {
        let cases = Self.fixture.array("build")!.compactMap(\.objectValue)
        #expect(cases.count == 80)
        for (n, c) in cases.enumerated() {
            let ics = IcsExport.build(blocks: records(c, "blocks"), exams: records(c, "exams"), subjects: records(c, "subjects"),
                                      alarmMin: c.int("alarmMin"), feed: c.bool("feed") ?? false, now: c.int("now")!, clock: clock)
            #expect(ics == c.string("ics"), "#\(n)")
        }
    }

    @Test("Odebíraný kalendář: bloky od dvou týdnů zpět, budoucí zkoušky, otisk bez razítka")
    func feed() throws {
        for (n, c) in Self.fixture.array("feed")!.compactMap(\.objectValue).enumerated() {
            // Data tak, jak jsou (i dva předměty se stejným id – upsert by je sloučil).
            var raw = AppDocument.empty.raw
            for (key, value) in c.object("data")! { raw[key] = value }
            let doc = try AppDocument(normalizing: .object(raw))
            let ics = IcsExport.feed(doc, includeExams: c.bool("includeExams")!, alarmMin: c.int("alarmMin"), now: c.int("now")!, clock: clock)
            #expect(ics == c.string("ics"), "#\(n)")
            #expect(IcsExport.hash(c.string("ics")!) == c.string("hash"), "#\(n) otisk")
        }
    }
}
