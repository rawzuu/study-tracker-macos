import Core
import Engine
import Foundation
import Persistence
import Sync
import Testing
@testable import AppModel

private let t0 = 1_792_300_000_000
private let minute = StudyClock.minute

/// Ručně posouvané hodiny.
@MainActor
private final class TestClock {
    var t = t0
}

@MainActor
private func makeApp(defaults: UserDefaults, settings: (inout Settings) -> Void = { _ in }) async throws -> AppStore {
    var seed = AppDocument.empty
    seed.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 0, "archived": false]), now: 1)
    seed.updateSettings(now: 1, settings)
    let local = try LocalStore.inMemory()
    let app = AppStore(environment: AppEnvironment(
        openStore: { local },
        secrets: InMemorySecretStore(),
        defaults: defaults,
        backupService: GitHubBackupService(),
        timing: SyncEngine.Timing(debounce: .milliseconds(10), interval: .seconds(3600), persistDelay: .milliseconds(5)),
        network: { AsyncStream { $0.finish() } },
        seed: seed
    ))
    await app.start()
    return app
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "st-timer-tests-\(UUID().uuidString)")!
}

@MainActor
@Suite("Časovač v aplikaci")
struct TimerStoreTests {
    @Test("Doběhnutý blok se uloží jako sezení a otevře hodnocení")
    func blockSavesSession() async throws {
        let app = try await makeApp(defaults: freshDefaults())
        let clock = TestClock()
        let timer = TimerStore(app: app) { clock.t }
        timer.configure(TimerSetup(subjectId: "anat", topic: "Lebka"))
        timer.start()
        #expect(timer.state.status == .running)

        clock.t += 25 * minute
        timer.refresh()
        let session = try #require(app.document.record(Session.self, id: "timer-\(t0)"))
        #expect(session.durationSec == 1500 && session.topic == "Lebka" && session.mode == "pomodoro")
        #expect(timer.pendingRating == session.id)
        #expect(timer.state.phase == .short)

        timer.saveRating(focus: 4, recall: "  Kosti lebky  ", note: "")
        let rated = try #require(app.document.record(Session.self, id: session.id))
        #expect(rated.focus == 4 && rated.recall == "Kosti lebky" && rated.note == "")
        #expect(timer.pendingRating == nil)
    }

    @Test("Bez dotazů po bloku se hodnocení neotevře")
    func noRatingWhenDisabled() async throws {
        let app = try await makeApp(defaults: freshDefaults()) {
            $0.askFocusRating = false
            $0.askRecall = false
        }
        let clock = TestClock()
        let timer = TimerStore(app: app) { clock.t }
        timer.configure(TimerSetup(subjectId: "anat"))
        timer.start()
        clock.t += 10 * minute
        timer.stop()
        #expect(app.document.record(Session.self, id: "timer-\(t0)")?.durationSec == 600)
        #expect(timer.pendingRating == nil)
    }

    @Test("Krátký blok se neuloží a aplikace to řekne")
    func tooShortNotice() async throws {
        let app = try await makeApp(defaults: freshDefaults())
        let clock = TestClock()
        let timer = TimerStore(app: app) { clock.t }
        timer.configure(TimerSetup(subjectId: "anat"))
        timer.start()
        clock.t += 30_000
        timer.finishWork()
        #expect(app.document.alive(Session.self).isEmpty)
        #expect(timer.notice == "Blok kratší než 1 min se neukládá")
    }

    @Test("Běžící blok přežije restart aplikace a po návratu se dožene")
    func survivesRestart() async throws {
        let defaults = freshDefaults()
        let app = try await makeApp(defaults: defaults)
        let clock = TestClock()
        let first = TimerStore(app: app) { clock.t }
        first.configure(TimerSetup(subjectId: "anat"))
        first.start()

        // „restart“: nový TimerStore nad stejnými UserDefaults, mezitím uběhlo 40 minut
        clock.t += 40 * minute
        let second = TimerStore(app: app) { clock.t }
        #expect(second.state.status == .running && second.state.workStartedAt == t0)
        second.refresh()
        #expect(app.document.record(Session.self, id: "timer-\(t0)")?.end == t0 + 25 * minute)
        #expect(second.state.status == .ready && second.state.phase == .work)
    }

    @Test("Výchozí režim z nastavení, dokud uživatel nic nezměnil")
    func defaultModeFromSettings() async throws {
        let app = try await makeApp(defaults: freshDefaults()) { $0.defaultMode = "52-17" }
        let timer = TimerStore(app: app)
        #expect(timer.state.modeId == "pomodoro")
        timer.refresh()
        #expect(timer.state.modeId == "52-17")
        #expect(timer.mode.name == "52 / 17")
    }

    @Test("Mezerník: start, pauza, pokračování")
    func toggle() async throws {
        let app = try await makeApp(defaults: freshDefaults())
        let clock = TestClock()
        let timer = TimerStore(app: app) { clock.t }
        timer.toggle()
        #expect(timer.state.status == .idle) // bez předmětu nic
        timer.configure(TimerSetup(subjectId: "anat"))
        timer.toggle()
        #expect(timer.state.status == .running)
        clock.t += minute
        timer.toggle()
        #expect(timer.state.status == .paused && timer.state.accumulated == minute)
        timer.toggle()
        #expect(timer.state.status == .running)
    }
}

@MainActor
@Suite("Horní lišta")
struct MenuBarStatusTests {
    @Test("V klidu jen ikona; běžící blok odpočítává, pauza drží čas")
    func states() async throws {
        let app = try await makeApp(defaults: freshDefaults())
        let clock = TestClock()
        let timer = TimerStore(app: app, effects: nil) { clock.t }
        let status = MenuBarStatus(timer: timer)
        status.render(at: clock.t)
        #expect(status.title == nil && status.symbol == "graduationcap")

        timer.configure(TimerSetup(subjectId: "anat", modeId: "pomodoro"))
        timer.start()
        clock.t += 61_000
        status.render(at: clock.t)
        #expect(status.title == "23:59" && status.symbol == "book")

        timer.pause()
        clock.t += 5 * minute
        status.render(at: clock.t)
        #expect(status.title == "23:59" && status.symbol == "pause.circle", "pauza čas nezmění")
    }
}

@MainActor
@Suite("Tlačítka v oznámení")
struct TimerActionTests {
    @Test("Po bloku: hodnocení z oznámení uloží soustředění, „Bez pauzy“ spustí další blok, „Ukončit“ sérii ukončí")
    func afterBlock() async throws {
        let app = try await makeApp(defaults: freshDefaults()) { $0.askFocusRating = true }
        let clock = TestClock()
        let timer = TimerStore(app: app) { clock.t }
        timer.configure(TimerSetup(subjectId: "anat", modeId: "pomodoro"))
        timer.start()
        // oznámení přišlo, ale aplikace konec bloku ještě nezpracovala – akce ho dožene
        clock.t += 25 * minute
        timer.perform(.focus(4))
        #expect(app.document.alive(Session.self).map(\.focus) == [4])
        #expect(timer.pendingRating == nil, "okno s hodnocením se zavře")
        #expect(timer.state.phase != .work && timer.state.status == .running, "pauza běží sama")

        // druhé hodnocení stejného bloku ho jen opraví
        timer.perform(.focus(5))
        #expect(app.document.alive(Session.self).map(\.focus) == [5])

        timer.perform(.skipBreak)
        #expect(timer.state.phase == .work && timer.state.status == .running)
        clock.t += 2 * minute
        timer.perform(.endSeries)
        #expect(timer.state.status == .idle)
        #expect(app.document.alive(Session.self).count == 2, "rozpracovaný blok se uložil")
    }

    @Test("Po pauze: „Začít další blok“; pauza, která čeká, jde spustit z oznámení")
    func afterBreak() async throws {
        let app = try await makeApp(defaults: freshDefaults()) { $0.autoStartBreaks = false }
        let clock = TestClock()
        let timer = TimerStore(app: app) { clock.t }
        timer.configure(TimerSetup(subjectId: "anat", modeId: "pomodoro"))
        timer.start()
        clock.t += 25 * minute
        timer.perform(.startBreak)
        #expect(timer.state.phase != .work && timer.state.status == .running)
        clock.t += 5 * minute
        timer.perform(.startWork)
        #expect(timer.state.phase == .work && timer.state.status == .running)
        #expect(timer.state.segmentStart == clock.t)
    }

    @Test("Tlačítka odpovídají nastavení; identifikátory jdou tam i zpět")
    func actions() {
        #expect(BlockNotifier.actions(phase: .work, autoBreak: true, autoWork: false, rating: true)
            == [.skipBreak, .endSeries, .focus(5), .focus(4), .focus(3), .focus(2), .focus(1)])
        #expect(BlockNotifier.actions(phase: .work, autoBreak: false, autoWork: false, rating: false) == [.startBreak, .skipBreak, .endSeries])
        #expect(BlockNotifier.actions(phase: .short, autoBreak: true, autoWork: true, rating: true) == [.endSeries])
        for a in [TimerAction.startBreak, .skipBreak, .startWork, .endSeries, .focus(1), .focus(5)] {
            #expect(TimerAction(identifier: a.identifier) == a)
        }
        #expect(TimerAction(identifier: "st.focus.6") == nil)
        #expect(TimerAction(identifier: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
        #expect(TimerAction.focus(5).title == "Soustředění 5 – hluboký flow")
    }
}

@MainActor
@Suite("Zkratky a Siri")
struct StudyActionsTests {
    private func actions() async throws -> (StudyActions, TimerStore, TestClock, AppStore) {
        let app = try await makeApp(defaults: freshDefaults()) { $0.dailyGoalMin = 120 }
        // týdenní cíl → „Co teď?“ má co doporučit
        app.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 300, "archived": false]))
        let clock = TestClock()
        let timer = TimerStore(app: app) { clock.t }
        return (StudyActions(store: app, timer: timer, advisor: Advisor(store: app)), timer, clock, app)
    }

    @Test("Začít učení: zadaný předmět, jinak doporučení; běžící blok nepřeruší")
    func start() async throws {
        let (actions, timer, clock, _) = try await actions()
        try await actions.ready()
        #expect(actions.subjects.map(\.name) == ["Anatomie"])
        let text = try actions.start(subjectId: "anat", topic: " Lebka ", modeId: "pomodoro")
        #expect(text == "Začínám: Anatomie – Lebka · 25 min (Pomodoro).")
        #expect(timer.state.status == .running && timer.state.topic == "Lebka")
        #expect(throws: StudyActions.Failure.blockRunning("Anatomie")) { try actions.start(subjectId: nil, topic: nil, modeId: nil) }

        clock.t += 61_000
        #expect(try actions.pause() == "Pozastaveno – zbývá 23:59.")
        #expect(throws: StudyActions.Failure.notRunning) { try actions.pause() }
        #expect(try actions.resume() == "Pokračuji – zbývá 23:59.")
        #expect(try actions.finish() == "Blok uložen (Anatomie). Dej si pauzu.")
        // během pauzy „Začít učení“ bez zadání pokračuje sérií
        #expect(try actions.start(subjectId: nil, topic: nil, modeId: nil).hasPrefix("Začínám: Anatomie"))
        #expect(timer.state.phase == .work && timer.state.status == .running)
        #expect(try actions.stop() == "Ukončeno, blok je uložený.")
        #expect(timer.state.status == .idle)
        #expect(throws: StudyActions.Failure.notRunning) { try actions.stop() }
    }

    @Test("Bez předmětu podle Co teď?; bez předmětů srozumitelná chyba")
    func recommendation() async throws {
        let (actions, timer, _, _) = try await actions()
        try await actions.ready()
        #expect(try actions.start(subjectId: nil, topic: nil, modeId: nil).hasPrefix("Začínám: Anatomie"))
        #expect(timer.state.subjectId == "anat")
        _ = try actions.stop()
        #expect(throws: StudyActions.Failure.noSubject) { try actions.start(subjectId: "neexistuje", topic: nil, modeId: nil) }
        // Odkaz nebo zkratka se starým id: smazaný ani archivovaný předmět blok nespustí.
        let (stale, staleTimer, _, staleApp) = try await self.actions()
        staleApp.upsert(Subject(raw: ["id": "old", "name": "Latina", "color": "#7d9cc0", "weeklyGoalMin": 0, "archived": true]))
        #expect(throws: StudyActions.Failure.noSubject) { try stale.start(subjectId: "old", topic: nil, modeId: nil) }
        staleApp.remove(.subjects, id: "anat")
        #expect(throws: StudyActions.Failure.noSubject) { try stale.start(subjectId: "anat", topic: nil, modeId: nil) }
        #expect(staleTimer.state.status == .idle)
        let (empty, _, _, app) = try await self.actions()
        app.remove(.subjects, id: "anat")
        #expect(throws: StudyActions.Failure.noSubject) { try empty.start(subjectId: nil, topic: nil, modeId: nil) }
        #expect(empty.whatNow() == "Teď není co doporučit – přidej předměty, cíle nebo zkoušky.")
    }

    @Test("Dnešní čas a Co teď? jako věta")
    func queries() async throws {
        let (actions, timer, clock, _) = try await actions()
        try await actions.ready()
        #expect(actions.today().text == "Dnes 0 min z 2 h, zbývá 2 h.")
        #expect(actions.whatNow().hasPrefix("Anatomie") && !actions.whatNow().contains("Pokračovat"))
        clock.t = Int(Date().timeIntervalSince1970 * 1000) - 30 * minute
        try actions.start(subjectId: "anat", topic: nil, modeId: "pomodoro")
        clock.t += 25 * minute
        timer.refresh()
        #expect(actions.today().minutes == 25)
    }
}
