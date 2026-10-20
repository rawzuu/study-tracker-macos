import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (`evaluate`, `toPersist`, `describe`) – Tools/parity/generate-achievements.ts.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

@Suite("Úspěchy: parita s webem")
struct AchievementsParityTests {
    private static let fixture: JSONObject = {
        let url = Bundle.module.url(forResource: "achievements", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.parse(Data(contentsOf: url)).objectValue!
    }()

    @Test("Úrovně, hodnoty, data získání, jednorázové a skryté úspěchy, co uložit")
    func evaluate() throws {
        let cases = Self.fixture.array("cases")!.compactMap(\.objectValue)
        #expect(cases.count == 40)
        for (n, c) in cases.enumerated() {
            let doc = try AppDocument(normalizing: c["data"]!)
            let now = c.int("now")!
            let res = Achievements.evaluate(doc, now: now, clock: clock)
            let families = c.array("families")!.compactMap(\.objectValue)
            #expect(res.families.map(\.family.id) == families.map { $0.string("id")! }, "#\(n) řady")
            for (r, w) in zip(res.families, families) {
                let at = "#\(n) \(r.family.id)"
                #expect(r.value == w.number("value"), "\(at) hodnota")
                #expect(r.tier == w.int("tier") && r.next == w.number("next") && r.progress == w.number("progress"), "\(at) úroveň")
                let tiers = w.array("tiers")!.compactMap(\.arrayValue)
                #expect(r.tiers.map(\.unlocked) == tiers.map { $0[0].boolValue! }, "\(at) odemčeno")
                #expect(r.tiers.map(\.at) == tiers.map { $0[1].numberValue.map { Int($0) } }, "\(at) kdy")
            }
            let singles = c.array("singles")!.compactMap(\.arrayValue)
            #expect(res.singles.map(\.single.id) == singles.map { $0[0].stringValue! }, "#\(n) jednorázové")
            #expect(res.singles.map(\.unlocked) == singles.map { $0[1].boolValue! }, "#\(n) jednorázové odemčeno")
            #expect(res.singles.map(\.at) == singles.map { $0[2].numberValue.map { Int($0) } }, "#\(n) jednorázové kdy")
            #expect(res.unlockedIds == c.array("unlockedIds")!.compactMap(\.stringValue) && res.total == c.int("total"), "#\(n) seznam")
            let persist = c.array("persist")!.compactMap(\.objectValue)
            let got = Achievements.toPersist(doc, res, now: now)
            #expect(got.map(\.id) == persist.map { $0.string("id")! } && got.map { $0.raw.int("at") } == persist.map { $0.int("at") }, "#\(n) uložit")
        }
    }

    @Test("Názvy a popisy všech 119 úspěchů")
    func describe() {
        let all = Self.fixture.array("describe")!.compactMap(\.objectValue)
        #expect(all.count == 119)
        for d in all {
            let got = Achievements.describe(d.string("id")!)
            #expect(got?.name == d.string("name") && got?.desc == d.string("desc"), "\(d.string("id")!)")
        }
    }
}
