import Core
import Engine
import Foundation
import Persistence
import Testing
@testable import AppModel

private let clock = StudyClock(timeZone: TimeZone(identifier: "Europe/Prague")!)

/// Sobota 17. 10. 2026 v `h:m` (den `d`).
private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Int {
    clock.ms(clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!)
}

@MainActor
private func store(seed: AppDocument, defaults: UserDefaults = UserDefaults(suiteName: "st-advisor-\(UUID().uuidString)")!) async -> AppStore {
    let local = try! LocalStore.inMemory()
    let store = AppStore(environment: AppEnvironment(
        openStore: { local }, secrets: InMemorySecretStore(), defaults: defaults, backupService: OfflineBackupService(),
        clock: clock, network: { AsyncStream { $0.finish() } }, seed: seed
    ))
    await store.start()
    return store
}

private var twoSubjects: AppDocument {
    var d = AppDocument.empty
    d.upsert(["a", "b"].map { Subject(raw: ["id": .string($0), "name": .string($0), "color": "#7b8cde", "weeklyGoalMin": 300, "archived": false]) }, now: 1)
    return d
}

@MainActor
@Suite("Co teď? pro všechna okna")
struct AdvisorTests {
    @Test("Doporučení se drží 5 minut a přepočítají se po změně dat")
    func caching() async {
        let app = await store(seed: twoSubjects)
        let advisor = Advisor(store: app)
        let first = advisor.recommendations(now: at(17, 10, 1))
        #expect(first.map(\.subjectId) == ["a", "b"])
        // o 3 minuty později stejný výsledek (skóre se mezitím trochu posunulo, pořadí se nemění pod rukama)
        #expect(advisor.recommendations(now: at(17, 10, 4)) == first)
        // po učení „a“ se doporučení hned přepočítá
        app.upsert(Session(raw: [
            "id": "s", "mode": "pomodoro", "interruptions": 0, "subjectId": "a", "topic": "Derivace",
            "start": .number(Double(at(17, 9))), "end": .number(Double(at(17, 10))), "durationSec": 3600, "note": "",
        ]))
        let after = advisor.recommendations(now: at(17, 10, 4))
        #expect(after.first?.subjectId == "b")
        #expect(after.first { $0.subjectId == "a" }?.title == "Pokračovat: Derivace")
        // další pětiminutovka spočítá znovu
        #expect(advisor.recommendations(now: at(17, 10, 6)) != after)
    }

    @Test("Ranní výzva: dopoledne, bez dnešního plánu, skrytí platí jen pro dnešek a na tomto Macu")
    func morningPrompt() async {
        let defaults = UserDefaults(suiteName: "st-advisor-\(UUID().uuidString)")!
        let app = await store(seed: twoSubjects, defaults: defaults)
        let advisor = Advisor(store: app)
        #expect(advisor.showsMorningPrompt(now: at(17, 8)))
        #expect(!advisor.showsMorningPrompt(now: at(17, 4, 59)))
        #expect(!advisor.showsMorningPrompt(now: at(17, 13)))

        advisor.dismissMorningPrompt(now: at(17, 8))
        #expect(!advisor.showsMorningPrompt(now: at(17, 9)))
        #expect(!Advisor(store: app).showsMorningPrompt(now: at(17, 9)), "skrytí přežije restart")
        #expect(advisor.showsMorningPrompt(now: at(18, 8)), "druhý den se ukáže znovu")

        app.upsert(PlanBlock(raw: ["id": "p", "subjectId": "a", "title": "", "start": .number(Double(at(18, 20))), "durationMin": 30, "done": true, "note": ""]))
        #expect(!advisor.showsMorningPrompt(now: at(18, 8)), "na dnešek už je něco v plánu")
        app.updateSettings { $0.morningPrompt = false }
        #expect(!advisor.showsMorningPrompt(now: at(19, 8)), "vypnuto v nastavení")
    }

    @Test("Bez předmětů ranní výzva není")
    func noSubjects() async {
        let advisor = Advisor(store: await store(seed: .empty))
        #expect(!advisor.showsMorningPrompt(now: at(17, 8)))
        #expect(advisor.recommendations(now: at(17, 8)).isEmpty)
    }
}
