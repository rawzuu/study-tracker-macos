import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (`trashItems`, `sessionsToCsv`) – Tools/parity/generate-backup.ts.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

@Suite("Koš a CSV: parita s webem")
struct BackupParityTests {
    private static let cases: [JSONObject] = {
        let url = Bundle.module.url(forResource: "backup", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.parse(Data(contentsOf: url)).objectValue!.array("cases")!.compactMap(\.objectValue)
    }()

    private static func document(_ c: JSONObject) throws -> AppDocument {
        var raw = AppDocument.empty.raw
        for (key, value) in c.object("data")! where key != "settings" { raw[key] = value }
        return try AppDocument(normalizing: .object(raw))
    }

    @Test("Koš: položky, popisky a pořadí jako na webu")
    func trash() throws {
        #expect(Self.cases.count == 40)
        var compared = 0
        for (n, c) in Self.cases.enumerated() {
            let got = Trash.items(try Self.document(c), now: c.int("now")!, clock: clock)
            let want = c.array("trash")!.compactMap(\.objectValue)
            #expect(got.map(\.key.rawValue) == want.map { $0.string("key")! }, "#\(n) druhy")
            #expect(got.map(\.id) == want.map { $0.string("id")! }, "#\(n) id")
            #expect(got.map(\.deletedAt) == want.map { $0.int("deletedAt")! }, "#\(n) kdy")
            #expect(got.map(\.title) == want.map { $0.string("title")! }, "#\(n) názvy")
            #expect(got.map(\.detail) == want.map { $0.string("detail")! }, "#\(n) podrobnosti")
            compared += want.count
        }
        #expect(compared > 100)
    }

    @Test("Sezení do CSV bajtově jako na webu")
    func csv() throws {
        for (n, c) in Self.cases.enumerated() {
            let got = SessionsCSV.make(try Self.document(c), clock: clock).components(separatedBy: "\r\n")
            let want = c.string("csv")!.components(separatedBy: "\r\n")
            for (g, w) in zip(got, want) where g != w { Issue.record("#\(n)\n\(g.debugDescription)\n\(w.debugDescription)") }
            #expect(got.count == want.count, "#\(n) řádky")
        }
    }
}
