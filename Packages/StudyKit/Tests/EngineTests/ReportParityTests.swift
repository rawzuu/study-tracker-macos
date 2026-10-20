import Core
import Foundation
import Testing
@testable import Engine

// Kontrolní data spočítal kód webu (`periodStats`, `highlights`, `calibrate`) – Tools/parity/generate-report.ts.
private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

@Suite("Měsíční report a kalibrace: parita s webem")
struct ReportParityTests {
    private static let fixture: JSONObject = {
        let url = Bundle.module.url(forResource: "report", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.parse(Data(contentsOf: url)).objectValue!
    }()

    private static func document(_ c: JSONObject) throws -> AppDocument {
        try AppDocument(normalizing: c["data"]!)
    }

    private func check(_ got: PeriodStats, _ want: JSONObject, _ at: String) {
        #expect(got.from == want.int("from") && got.to == want.int("to") && got.days == want.int("days"), "\(at) období")
        #expect(got.total == want.int("total") && got.sessions == want.int("sessions") && got.activeDays == want.int("activeDays"), "\(at) součty")
        #expect(got.consistency == want.number("consistency"), "\(at) pravidelnost")
        #expect(got.avgPerActiveDay == want.number("avgPerActiveDay") && got.avgSession == want.number("avgSession"), "\(at) průměry")
        #expect(got.longestSession?.id == want.string("longestSession"), "\(at) nejdelší blok")
        #expect(got.bestDay?.key == want.object("bestDay")?.string("key") && got.bestDay?.sec == want.object("bestDay")?.int("sec"), "\(at) nejlepší den")
        #expect(got.longestStreak == want.int("longestStreak"), "\(at) série")
        #expect(got.focus == want.number("focus"), "\(at) soustředění")
        #expect(got.deepShare == want.number("deepShare") && got.interruptionsPerHour == want.number("interruptionsPerHour"), "\(at) hluboká práce")
        #expect(got.weekdayAvg == want.array("weekdayAvg")!.compactMap(\.numberValue), "\(at) dny v týdnu")
        #expect(got.hourMinutes == want.array("hourMinutes")!.compactMap(\.numberValue), "\(at) hodiny")
        #expect(got.peakWindow?.from == want.object("peakWindow")?.int("from"), "\(at) špička")
        let parts = want.array("dayparts")!.compactMap(\.objectValue)
        #expect(got.dayparts.map(\.min) == parts.map { $0.number("min")! } && got.dayparts.map(\.focus) == parts.map { $0.number("focus") }, "\(at) části dne")
        #expect(got.chronotype == want.string("chronotype"), "\(at) chronotyp")
        let perSubject = want.array("perSubject")!.compactMap(\.arrayValue).map { ($0[0].stringValue!, Int($0[1].numberValue!)) }
        #expect(got.perSubject.map(\.id) == perSubject.map(\.0) && got.perSubject.map(\.sec) == perSubject.map(\.1), "\(at) předměty")
        #expect(got.perDay.map(\.key) == want.array("perDay")!.compactMap(\.arrayValue).map { $0[0].stringValue! }, "\(at) dny")
        #expect(got.planAdherence == want.number("planAdherence") && got.plannedSec == want.int("plannedSec"), "\(at) plán")
    }

    @Test("Souhrn měsíce, minulého měsíce a týdne; postřehy")
    func periods() throws {
        let cases = Self.fixture.array("cases")!.compactMap(\.objectValue)
        #expect(cases.count == 48)
        for (n, c) in cases.enumerated() {
            let doc = try Self.document(c)
            let now = c.int("now")!, y = c.int("y")!, m = c.int("m")!
            let s = doc.settings
            let all = doc.alive(Session.self), blocks = doc.records(PlanBlock.self)
            let range = Report.monthRange(year: y, month: m, clock: clock)
            let prevMonth = Report.shift(year: y, month: m, by: -1)
            let prevRange = Report.monthRange(year: prevMonth.year, month: prevMonth.month, clock: clock)
            let cur = PeriodStats(sessions: all, blocks: blocks, from: range.from, to: range.to, restDays: s.streakRestDays, minMin: s.streakMinMin, now: now, clock: clock)
            let prev = PeriodStats(sessions: all, blocks: blocks, from: prevRange.from, to: prevRange.to, restDays: s.streakRestDays, minMin: s.streakMinMin, now: now, clock: clock)
            let report = c.object("report")!
            check(cur, report.object("cur")!, "#\(n) měsíc")
            check(prev, report.object("prev")!, "#\(n) minulý měsíc")
            #expect(Report.highlights(cur, prev, subjects: doc.records(Subject.self), clock: clock) == report.array("highlights")!.compactMap(\.stringValue), "#\(n) postřehy")
            let weekFrom = c.int("weekFrom")!
            let week = PeriodStats(sessions: all, blocks: blocks, from: weekFrom, to: clock.addDays(weekFrom, 7), restDays: s.streakRestDays, minMin: s.streakMinMin, now: now, clock: clock)
            check(week, c.object("week")!, "#\(n) týden")
        }
    }

    @Test("Návrhy kalibrace: denní cíl, týdenní cíle, okno ranního plánu")
    func calibration() throws {
        var compared = 0
        for (n, c) in Self.fixture.array("cases")!.compactMap(\.objectValue).enumerated() {
            let doc = try Self.document(c)
            let end = c.int("end")!
            let want = c.object("calibration")!
            #expect(Calibrate.enoughData(doc, end: end, clock: clock) == want.bool("enough"), "#\(n) dost dat")
            let got = Calibrate.suggestions(doc, end: end, clock: clock)
            let expected = want.array("suggestions")!.compactMap(\.objectValue)
            #expect(got.map(\.key.rawValue) == expected.map { $0.string("key")! }, "#\(n) klíče")
            for (g, w) in zip(got, expected) {
                #expect(g.title == w.string("title") && g.current == w.string("current") && g.proposed == w.string("proposed"), "#\(n) \(g.key) hodnoty")
                #expect(g.reasons == w.array("reasons")!.compactMap(\.stringValue), "#\(n) \(g.key) důvody")
                #expect(g.before == w["before"] && g.after == w["after"], "#\(n) \(g.key) před a po")
                if let settings = w.object("settings") { #expect(g.settings == settings, "#\(n) \(g.key) nastavení") }
                if let subjects = w.array("subjects")?.compactMap(\.objectValue) {
                    #expect(g.subjects.map(\.id) == subjects.map { $0.string("id")! } && g.subjects.map(\.weeklyGoalMin) == subjects.map { $0.int("weeklyGoalMin")! }, "#\(n) cíle předmětů")
                }
                compared += 1
            }
        }
        #expect(compared > 60)
    }

    @Test("Procenta změny a vážený kvantil")
    func helpers() {
        for c in Self.fixture.array("pct")!.compactMap(\.objectValue) {
            #expect(Report.pct(c.number("cur")!, c.number("prev")!) == c.int("pct"))
        }
        for c in Self.fixture.array("quantiles")!.compactMap(\.objectValue) {
            #expect(Calibrate.weightedQuantile(c.array("values")!.compactMap(\.numberValue), c.array("weights")!.compactMap(\.numberValue), c.number("q")!) == c.number("result"))
        }
    }
}
