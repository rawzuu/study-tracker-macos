import Engine
import Testing
@testable import Features

// Stejná pravidla jako `TimerRing` na webu.
private let t0 = 1_792_300_000_000
private let minute = 60_000

private func state(_ mode: TimerMode, after ms: Int = 0, subject: Bool = true) -> TimerState {
    var s = TimerState(modeId: mode.id)
    s.configure(TimerSetup(subjectId: subject ? "a" : ""))
    s.start(now: t0, mode: mode)
    return s
}

@Suite("Kruh časovače")
struct TimerRingModelTests {
    let pomodoro = TimerMode.find("pomodoro", presets: [])

    @Test("V klidu: délka režimu, minuta na dílek, stupnice po 5")
    func idle() {
        let m = TimerRingModel(state: TimerState(modeId: "pomodoro"), mode: pomodoro, now: t0)
        #expect(m.time == "25:00" && m.phaseLabel == "Připraveno" && m.tone == .idle)
        #expect(m.segments.count == 25 && !m.segments.contains(.lit))
        #expect(m.labels.map(\.minute) == [0, 5, 10, 15, 20])
        #expect(m.rounds?.total == 4 && m.rounds?.done == 0)
    }

    @Test("Běží: zbývající čas, hotové dílky a právě běžící dílek")
    func running() {
        let m = TimerRingModel(state: state(pomodoro), mode: pomodoro, now: t0 + 10 * minute + 30_000)
        #expect(m.time == "14:30" && m.phaseLabel == "Učení" && m.tone == .work)
        #expect(m.segments.filter { $0 == .lit }.count == 10)
        #expect(m.segments[10] == .now)
    }

    @Test("Krátká pauza: půlminutové dílky; dlouhý blok: víc minut na dílek")
    func segmentSizes() {
        var s = state(pomodoro)
        _ = s.advance(now: t0 + 25 * minute, mode: pomodoro, rules: TimerRules())
        let rest = TimerRingModel(state: s, mode: pomodoro, now: t0 + 25 * minute)
        #expect(rest.segments.count == 10 && rest.labels.map(\.minute) == [0, 1, 2, 3, 4])
        #expect(rest.phaseLabel == "Pauza" && rest.tone == .rest && rest.rounds?.done == 1)

        let ultradian = TimerMode.find("ultradian", presets: [])
        let long = TimerRingModel(state: state(ultradian), mode: ultradian, now: t0)
        #expect(long.segments.count == 45 && long.labels.map(\.minute) == [0, 15, 30, 45, 60, 75])
    }

    @Test("Stopky: hodina dokola, čas nahoru, bez kol")
    func stopwatch() {
        let mode = TimerMode.find("stopwatch", presets: [])
        let m = TimerRingModel(state: state(mode), mode: mode, now: t0 + 75 * minute)
        #expect(m.time == "1:15:00")
        #expect(m.segments.count == 60 && m.segments.filter { $0 == .lit }.count == 15)
        #expect(m.labels.map(\.minute) == [0, 15, 30, 45])
        #expect(m.rounds == nil)
    }

    @Test("Pozastaveno: tlumené barvy")
    func paused() {
        var s = state(pomodoro)
        s.pause(now: t0 + minute)
        #expect(TimerRingModel(state: s, mode: pomodoro, now: t0 + 9 * minute).tone == .paused)
        #expect(TimerRingModel(state: s, mode: pomodoro, now: t0 + 9 * minute).time == "24:00")
    }
}
