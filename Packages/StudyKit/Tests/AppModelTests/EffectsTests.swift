import Core
import Engine
import Foundation
import Persistence
import Sync
import Testing
@testable import AppModel

/// Deterministická náhoda pro testy (SplitMix64).
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func rms(_ xs: [Float]) -> Float {
    (xs.reduce(0) { $0 + $1 * $1 } / Float(max(1, xs.count))).squareRoot()
}

/// Počká, až podmínka platí (přechody hlasitosti běží v reálném čase).
@MainActor
private func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("Zvuky")
struct SoundSynthTests {
    @Test("Šum: 12 s smyčka bez švu, rozumná hlasitost", arguments: [NoiseType.brown, .pink, .white])
    func noise(_ type: NoiseType) {
        var rng = SeededRNG(state: 42)
        let xs = SoundSynth.noise(type, sampleRate: 8_000, using: &rng)
        #expect(xs.count == 96_000)
        #expect(xs.allSatisfy { abs($0) < 1 })
        #expect(rms(xs) > 0.01)
        if type == .brown {
            // hnědý šum se mění pomalu → konec navazuje na začátek
            #expect(abs(xs[xs.count - 1] - xs[0]) < 0.1)
        }
    }

    @Test("Zvonek: tři tóny, ticho na začátku, doznění", arguments: SoundSynth.Chime.allCases)
    func chime(_ kind: SoundSynth.Chime) {
        let rate = 44_100.0
        let xs = SoundSynth.chime(kind, sampleRate: rate)
        #expect(xs.count == Int(1.68 * rate))
        #expect(xs[0..<Int(0.02 * rate)].allSatisfy { $0 == 0 })
        #expect(xs.map(abs).max()! <= 0.75)
        #expect(rms(Array(xs[Int(0.05 * rate)..<Int(0.3 * rate)])) > 0.05)
        #expect(rms(Array(xs.suffix(Int(0.05 * rate)))) < 0.001)
    }
}

@MainActor
@Suite("Přehrávání (bez reproduktoru)")
struct AudioOutputTests {
    @Test("Šum hraje jen během bloku; po zastavení engine stojí (žádné CPU)")
    func noiseStopsEngine() async throws {
        let audio = AudioOutput(offline: true)
        #expect(!audio.isRunning)
        audio.playNoise(.brown, volume: 0.6)
        #expect(audio.isRunning && audio.noise == .brown)
        try await Task.sleep(for: .milliseconds(1_700)) // náběh 1,5 s
        #expect(rms(try audio.render(frames: 4096)) > 0.001)

        audio.stopNoise(fade: 0.1)
        #expect(await eventually { !audio.isRunning })
        #expect(audio.noise == .off)
    }

    @Test("Zvonek dozní a engine se zastaví")
    func chimeStopsEngine() async throws {
        let audio = AudioOutput(offline: true)
        audio.chime(.workEnd, volume: 1)
        #expect(audio.isRunning)
        #expect(rms(try audio.render(frames: 4096)) > 0.01)
        #expect(await eventually(timeout: .seconds(4)) { !audio.isRunning })
    }

    @Test("Efekty: šum podle stavu časovače a nastavení, zvonek jen se zapnutým zvukem")
    func liveEffects() async throws {
        let audio = AudioOutput(offline: true)
        let effects = LiveTimerEffects(audio: audio)
        var settings = Settings(raw: Schema.defaultSettings)
        settings.noiseType = .pink
        var state = TimerState(modeId: "pomodoro")
        state.configure(TimerSetup(subjectId: "a"))
        state.start(now: 0, mode: TimerMode.builtin[0])

        effects.update(state: state, phaseEnd: 1_500_000, settings: settings, now: 0)
        #expect(audio.noise == .pink)
        state.pause(now: 1000)
        effects.update(state: state, phaseEnd: nil, settings: settings, now: 1000)
        #expect(audio.noise == .off)
        #expect(await eventually { !audio.isRunning })

        settings.sound = false
        effects.handle(.workEnded, settings: settings)
        #expect(!audio.isRunning)
        settings.sound = true
        effects.handle(.workEnded, settings: settings)
        #expect(audio.isRunning)
    }

    @Test("Ukázka šumu skončí sama, blok ji převezme")
    func preview() async throws {
        let audio = AudioOutput(offline: true)
        let effects = LiveTimerEffects(audio: audio)
        effects.previewNoise(.white, volume: 0.5)
        #expect(effects.isPreviewing && audio.noise == .white)
        // Mimo blok ukázku nepřeruší ani aktualizace stavu.
        effects.update(state: TimerState(modeId: "pomodoro"), phaseEnd: nil, settings: Settings(raw: Schema.defaultSettings), now: 0)
        #expect(audio.noise == .white)
    }
}

/// Zapisuje, co časovač po efektech chtěl.
@MainActor
private final class RecordingEffects: TimerEffects {
    var updates: [(status: TimerStatus, phase: TimerPhase, phaseEnd: Int?)] = []
    var events: [TimerEvent] = []
    var isPreviewing = false
    func update(state: TimerState, phaseEnd: Int?, settings: Settings, now: Int) {
        updates.append((state.status, state.phase, phaseEnd))
    }
    func handle(_ event: TimerEvent, settings: Settings) { events.append(event) }
    func previewNoise(_ type: NoiseType, volume: Double) { isPreviewing = true }
    func previewChime(volume: Double) {}
}

@MainActor
@Suite("Časovač a efekty")
struct TimerEffectsWiringTests {
    private func makeApp() async throws -> AppStore {
        var seed = AppDocument.empty
        seed.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "archived": false]), now: 1)
        let local = try LocalStore.inMemory()
        let app = AppStore(environment: AppEnvironment(
            openStore: { local }, secrets: InMemorySecretStore(),
            defaults: UserDefaults(suiteName: "st-fx-\(UUID().uuidString)")!,
            backupService: GitHubBackupService(),
            timing: SyncEngine.Timing(debounce: .milliseconds(10), interval: .seconds(3600), persistDelay: .milliseconds(5)),
            network: { AsyncStream { $0.finish() } }, seed: seed
        ))
        await app.start()
        return app
    }

    @Test("Každá změna stavu jde do efektů s koncem fáze; přirozený konec zazvoní")
    func wiring() async throws {
        let app = try await makeApp()
        let fx = RecordingEffects()
        var t = 1_000_000
        let timer = TimerStore(app: app, effects: fx) { t }
        timer.configure(TimerSetup(subjectId: "anat"))
        timer.start()
        #expect(fx.updates.last?.status == .running && fx.updates.last?.phaseEnd == 1_000_000 + 25 * 60_000)
        t += 25 * 60_000
        timer.refresh()
        #expect(fx.events.contains(.workEnded))
        #expect(fx.updates.last?.phase == .short && fx.updates.last?.phaseEnd == t + 5 * 60_000)
        timer.stop()
        #expect(fx.updates.last?.status == .idle && fx.updates.last?.phaseEnd == nil)
    }

    @Test("Odkaz před načtením dat počká, pak blok spustí")
    func pendingLink() async throws {
        let local = try LocalStore.inMemory()
        var seed = AppDocument.empty
        seed.upsert(Subject(raw: ["id": "anat", "name": "Anatomie", "archived": false]), now: 1)
        let app = AppStore(environment: AppEnvironment(
            openStore: { local }, secrets: InMemorySecretStore(),
            defaults: UserDefaults(suiteName: "st-fx-\(UUID().uuidString)")!,
            backupService: GitHubBackupService(),
            timing: SyncEngine.Timing(debounce: .milliseconds(10), interval: .seconds(3600), persistDelay: .milliseconds(5)),
            network: { AsyncStream { $0.finish() } }, seed: seed
        ))
        let timer = TimerStore(app: app)
        timer.open(TimerLink(subject: "anat", topic: "Lebka"))
        #expect(timer.state.status == .idle)
        await app.start()
        timer.refresh()
        #expect(timer.state.status == .running && timer.state.subjectId == "anat" && timer.state.topic == "Lebka")
    }
}
