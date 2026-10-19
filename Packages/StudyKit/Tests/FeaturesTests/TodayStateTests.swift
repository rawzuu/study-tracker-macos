import Core
import Foundation
import Testing
@testable import Engine
@testable import Features

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

private func at(_ h: Int, _ min: Int = 0, day: Int = 17) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: min))!)
}

/// Sobota 17. 10. 2026: hotový blok 9:00, sezení mimo plán 11:00, zmeškaný blok 10:00,
/// blok 17:00, zítra 9:00; zápočet z anatomie v úterý.
private func document() -> AppDocument {
    var d = AppDocument.empty
    d.upsert([
        Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 360]),
        Subject(raw: ["id": "fyz", "name": "Fyziologie", "color": "#7fa6c9", "weeklyGoalMin": 120]),
    ], now: 1)
    func session(_ id: String, _ subject: String, _ start: Int, min: Int, topic: String = "") -> Session {
        Session(raw: ["id": .string(id), "subjectId": .string(subject), "start": .number(Double(start)), "end": .number(Double(start + min * 60_000)),
                      "durationSec": .number(Double(min * 60)), "topic": .string(topic), "mode": "pomodoro", "interruptions": 0, "note": ""])
    }
    func block(_ id: String, _ subject: String, _ start: Int, min: Int, done: Bool, title: String = "") -> PlanBlock {
        PlanBlock(raw: ["id": .string(id), "subjectId": .string(subject), "title": .string(title), "start": .number(Double(start)),
                        "durationMin": .number(Double(min)), "done": .bool(done)])
    }
    d.upsert([session("s1", "anat", at(9, 5), min: 45, topic: "Lebka"), session("s2", "fyz", at(11), min: 25, topic: "Srdce")], now: 2)
    d.upsert([
        block("done", "anat", at(9), min: 50, done: true, title: "Lebka"),
        block("missed", "fyz", at(10), min: 30, done: false),
        block("later", "fyz", at(17), min: 45, done: false, title: "Ledviny"),
        block("tomorrow", "anat", at(9, day: 18), min: 50, done: false),
    ], now: 3)
    d.upsert(Exam(raw: ["id": "x", "subjectId": "anat", "name": "Zápočet z anatomie", "date": "2026-10-20", "time": "", "note": ""]), now: 4)
    d.updateSettings(now: 5) { $0.dailyGoalMin = 120 }
    return d
}

private func recommendation(_ subject: String, _ title: String, minutes: Int) -> Recommendation {
    Recommendation(key: "\(subject):continue", subjectId: subject, activity: .continue, title: title, topic: title, minutes: minutes,
                   modeId: "pomodoro", score: 1, signals: .init(), reasons: ["zkouška za 3 dny"], planBlockId: nil)
}

private func items(_ s: TodayState, _ part: TodayState.Part) -> [TodayState.Item] {
    s.sections.first { $0.part == part }?.entries.compactMap { if case .item(let i) = $0 { i } else { nil } } ?? []
}

private func gaps(_ s: TodayState) -> [TodayState.Gap] {
    s.sections.flatMap(\.entries).compactMap { if case .gap(let g) = $0 { g } else { nil } }
}

@Suite("Dnes – seznam dne")
struct TodayStateTests {
    @Test("Bloky a sezení po částech dne: hotové, zmeškané, čekající; sezení pod hotovým blokem se neopakuje")
    func sections() {
        let s = TodayState(document: document(), now: at(15), clock: clock)
        #expect(s.sections.map(\.part) == [.morning, .afternoon])
        let morning = items(s, .morning)
        #expect(morning.map(\.id) == ["done", "missed", "session.s2"])
        #expect(morning.map(\.status) == [.done, .missed, .done])
        #expect(morning[2].title == "Srdce" && morning[2].planBlockId == nil)
        #expect(items(s, .afternoon).map(\.id) == ["later"] && items(s, .afternoon)[0].status == .open)
        #expect(s.sections[0].meta == "3 bloky · 1 h 45 min")
        #expect(s.tomorrow.map(\.id) == ["tomorrow"])
        #expect(s.goalSec == 7200 && s.remainingSec == 7200 - 70 * 60)
    }

    @Test("Blízká zkouška u bloků předmětu; druh zkoušky z názvu")
    func examHints() {
        let s = TodayState(document: document(), now: at(15), clock: clock)
        #expect(items(s, .morning)[0].examHint == "zápočet za 3 dny")
        #expect(items(s, .afternoon)[0].examHint == nil)
        #expect(TodayState.kind(of: "Test z biochemie") == "test" && TodayState.kind(of: "Anatomie I") == "zkouška")
    }

    @Test("Běžící blok: z plánu se označí, bez plánu přibude vlastní položka")
    func running() {
        let planned = TodayState(document: document(), now: at(17, 10), clock: clock,
                                 running: .init(planBlockId: "later", subjectId: "fyz", topic: "Ledviny", start: at(17), end: at(17, 45)))
        #expect(items(planned, .afternoon).map(\.status) == [.running])
        let free = TodayState(document: document(), now: at(15, 10), clock: clock,
                              running: .init(planBlockId: nil, subjectId: "anat", topic: "Svaly", start: at(15), end: at(15, 25)))
        let timer = items(free, .afternoon).first { $0.id == "timer" }
        #expect(timer?.status == .running && timer?.title == "Svaly" && timer?.examHint == "zápočet za 3 dny")
    }

    @Test("Volné chvíle od teď do konce dne s pauzou kolem bloků; návrhy z doporučení, nejvýš do délky chvíle")
    func freeTime() {
        let recs = [recommendation("anat", "Příprava na zápočet", minutes: 50), recommendation("fyz", "Ledviny", minutes: 300),
                    Recommendation(key: "plan", subjectId: "fyz", activity: .plan, title: "Blok", topic: "", minutes: 45, modeId: "pomodoro",
                                   score: 1, signals: .init(), reasons: [], planBlockId: "later")]
        let s = TodayState(document: document(), now: at(15, 2), clock: clock, recommendations: recs)
        let g = gaps(s)
        // 15:15 (zaokrouhleno) – 16:50 (pauza před blokem 17:00) a 17:55 – 22:00 (konec plánovaného dne)
        #expect(g.map(\.start) == [at(15, 15), at(17, 55)] && g.map(\.end) == [at(16, 50), at(22)])
        #expect(g[0].suggestion?.title == "Příprava na zápočet" && g[0].suggestion?.minutes == 50 && g[0].suggestion?.start == at(15, 15))
        // Delší doporučení se zkrátí na délku chvíle; doporučení k bloku plánu se nenavrhuje.
        #expect(g[1].suggestion?.subject.id == "fyz" && g[1].suggestion?.minutes == 245 && g[1].suggestion?.start == at(17, 55))
        #expect(TodayState(document: document(), now: at(15), clock: clock).sections.flatMap(\.entries).contains {
            if case .gap(let gap) = $0 { gap.suggestion == nil } else { false }
        })
    }

    @Test("Obsazený čas z kalendáře je v seznamu a volná chvíle se mu vyhne")
    func busy() {
        let busy = TodayState.Busy(id: "trenink", title: "Trénink", start: at(19), end: at(20, 30))
        let s = TodayState(document: document(), now: at(15), clock: clock, external: [busy])
        #expect(s.sections.flatMap(\.entries).contains(.busy(busy)))
        #expect(gaps(s).map(\.end).contains(at(18, 50)) && gaps(s).map(\.start).contains(at(20, 40)))
    }

    @Test("Pozdě večer už žádná volná chvíle")
    func lateEvening() {
        #expect(gaps(TodayState(document: document(), now: at(21, 40), clock: clock)).isEmpty)
    }
}

@Suite("Plán dne – volná místa")
struct FreeTimeTests {
    @Test("Mezi obsazenými úseky s pauzou 10 min, jen dost dlouhá")
    func freeTime() {
        let h = 3_600_000, m = 60_000
        let busy = [BusyInterval(start: 12 * h, end: 12 * h + 30 * m), BusyInterval(start: 9 * h, end: 10 * h)]
        let free = DayPlan.freeTime(busy, from: 8 * h, to: 14 * h, minutes: 30)
        #expect(free == [BusyInterval(start: 8 * h, end: 8 * h + 50 * m), BusyInterval(start: 10 * h + 10 * m, end: 11 * h + 50 * m),
                         BusyInterval(start: 12 * h + 40 * m, end: 14 * h)])
        #expect(DayPlan.freeTime(busy, from: 8 * h, to: 14 * h, minutes: 60).count == 2)
        #expect(DayPlan.freeTime([BusyInterval(start: 7 * h, end: 15 * h)], from: 8 * h, to: 14 * h, minutes: 30).isEmpty)
    }
}
