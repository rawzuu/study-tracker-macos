import Core
import Engine
import Foundation
import Persistence
import Sync
import Testing
@testable import AppModel

private let t0 = 1_792_300_000_000
private let minute = StudyClock.minute

@MainActor
private final class Clock {
    var t = t0
    var idle: Double = 0
}

/// Zapisuje jen oznámení o nepřítomnosti.
@MainActor
private final class AwayEffects: TimerEffects {
    var away: [Int] = []
    func update(state: TimerState, phaseEnd: Int?, settings: Settings, now: Int) {}
    func handle(_ event: TimerEvent, settings: Settings) {}
    func previewNoise(_ type: NoiseType, volume: Double) {}
    var isPreviewing: Bool { false }
    func previewChime(volume: Double) {}
    func awayPaused(minutes: Int) { away.append(minutes) }
}

@MainActor
private func makeApp() async throws -> AppStore {
    var seed = AppDocument.empty
    seed.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "color": "#c98a5b", "weeklyGoalMin": 300, "archived": false]), now: 1)
    let local = try LocalStore.inMemory()
    let app = AppStore(environment: AppEnvironment(
        openStore: { local }, secrets: InMemorySecretStore(), defaults: UserDefaults(suiteName: "st-mac-\(UUID().uuidString)")!,
        backupService: GitHubBackupService(),
        timing: SyncEngine.Timing(debounce: .milliseconds(10), interval: .seconds(3600), persistDelay: .milliseconds(5)),
        network: { AsyncStream { $0.finish() } }, seed: seed
    ))
    await app.start()
    return app
}

@MainActor
@Suite("Mac: automatická pauza, zkratky při bloku, souhrn týdne")
struct MacAutomationTests {
    private func running() async throws -> (TimerStore, AwayMonitor, MacPreferences, Clock, AwayEffects) {
        let app = try await makeApp()
        let clock = Clock()
        let effects = AwayEffects()
        let timer = TimerStore(app: app, effects: effects) { clock.t }
        let prefs = MacPreferences(defaults: app.defaults)
        let monitor = AwayMonitor(timer: timer, prefs: prefs, idleSeconds: { clock.idle }, now: { clock.t })
        timer.configure(TimerSetup(subjectId: "anat"))
        timer.start()
        return (timer, monitor, prefs, clock, effects)
    }

    @Test("Po nečinnosti se blok pozastaví k poslední aktivitě; po návratu oznámení, čas jde přičíst")
    func idle() async throws {
        let (timer, monitor, prefs, clock, effects) = try await running()
        prefs.awayMinutes = 5
        clock.t += 4 * minute
        clock.idle = 240
        monitor.check()
        #expect(timer.state.status == .running, "4 min nečinnosti nestačí")
        clock.t += 8 * minute
        clock.idle = 9 * 60
        monitor.check()
        // Poslední aktivita před 9 min = 3 min od začátku bloku
        #expect(timer.state.status == .paused && timer.state.accumulated == 3 * minute)
        clock.t += 1 * minute
        clock.idle = 2
        monitor.check()
        #expect(effects.away == [10])
        timer.resumeCountingAway()
        #expect(timer.state.status == .running && timer.state.accumulated == 13 * minute)
        #expect(timer.away == nil)
    }

    @Test("Zamčení pozastaví hned; krátké zamčení pokračuje samo; pauza a vypnuté hlídání se nepozastavují")
    func lock() async throws {
        let (timer, monitor, prefs, clock, effects) = try await running()
        clock.t += 2 * minute
        monitor.left()
        #expect(timer.state.status == .paused && timer.state.accumulated == 2 * minute)
        clock.t += 20_000
        clock.idle = 1
        monitor.check()
        #expect(effects.away.isEmpty && timer.state.status == .running, "20 s – pokračuje bez oznámení")

        prefs.awayOnLock = false
        monitor.left()
        #expect(timer.state.status == .running)
        prefs.awayMinutes = 0
        clock.idle = 3600
        monitor.check()
        #expect(timer.state.status == .running, "nečinnost vypnutá")

        prefs.awayMinutes = 2
        prefs.awayOnLock = true
        timer.finishWork()
        #expect(timer.state.phase != .work)
        monitor.left()
        monitor.check()
        #expect(timer.state.status == .running, "pauza (odpočinek) běží dál")
    }

    @Test("Zkratky na začátku a konci bloku; pozastavení není konec; vypnuté nic nespouští")
    func shortcuts() async throws {
        let app = try await makeApp()
        let clock = Clock()
        let timer = TimerStore(app: app) { clock.t }
        let prefs = MacPreferences(defaults: app.defaults)
        var ran: [String] = []
        let automation = BlockAutomation(timer: timer, prefs: prefs) { ran.append($0) }
        automation.start()
        timer.configure(TimerSetup(subjectId: "anat"))
        timer.start()
        automation.update()
        #expect(ran.isEmpty, "vypnuto")
        timer.stop()
        automation.update()

        prefs.shortcutsEnabled = true
        prefs.startShortcut = " Nerušit zapnout "
        prefs.endShortcut = "Nerušit vypnout"
        timer.start()
        automation.update()
        timer.pause()
        automation.update()
        timer.resume()
        automation.update()
        clock.t += 25 * minute
        timer.refresh()
        automation.update()
        #expect(ran == ["Nerušit zapnout", "Nerušit vypnout"])
    }

    @Test("Souhrn týdne jednou za týden, od pondělí 8:00")
    func weekly() async throws {
        let app = try await makeApp()
        let prefs = MacPreferences(defaults: app.defaults)
        var posted: [WeeklySummary.Text] = []
        let notifier = WeeklySummaryNotifier(app: app, prefs: prefs) { posted.append($0) }
        // Aktuální týden: Po 8:00 už je za námi (nebo ne) – souhrn se pošle nejvýš jednou.
        notifier.check()
        notifier.check()
        // Odesílá se z úlohy (Soustředění se čte z databáze).
        try await Task.sleep(for: .milliseconds(100))
        #expect(posted.count <= 1)
        let mondayMorning = app.nowMs >= app.clock.startOfWeek(app.nowMs) + 8 * 3_600_000
        #expect(posted.count == (mondayMorning ? 1 : 0))
        if mondayMorning { #expect(posted.first?.body.contains("týdenního cíle (5 h)") == true) }
        prefs.weeklySummary = false
        app.defaults.removeObject(forKey: WeeklySummaryNotifier.sentKey)
        notifier.check()
        try await Task.sleep(for: .milliseconds(100))
        #expect(posted.count == (mondayMorning ? 1 : 0), "vypnuto")
    }

    @Test("Nastavení Macu: výchozí hodnoty a uložení zkratek")
    func preferences() async throws {
        let defaults = UserDefaults(suiteName: "st-mac-prefs-\(UUID().uuidString)")!
        let prefs = MacPreferences(defaults: defaults)
        #expect(prefs.awayMinutes == 10 && prefs.awayOnLock && !prefs.shortcutsEnabled && prefs.weeklySummary)
        #expect(prefs.toggleHotKey == .defaultToggle && prefs.toggleHotKey?.display == "⌃⌥P" && prefs.showHotKey == nil)
        prefs.toggleHotKey = nil
        prefs.showHotKey = HotKey(keyCode: 1, modifiers: HotKey.command | HotKey.shift, key: "S")
        let again = MacPreferences(defaults: defaults)
        #expect(again.toggleHotKey == nil, "vypnutá zkratka zůstane vypnutá")
        #expect(again.showHotKey?.display == "⇧⌘S")
    }
}
