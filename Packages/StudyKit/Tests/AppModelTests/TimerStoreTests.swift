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
