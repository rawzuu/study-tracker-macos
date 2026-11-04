import Core
import Foundation
import Testing
@testable import Engine

// Jen na Macu: pauzy jako mezery, záznam končí poslední prací, dlouhá pauza blok ukončí.
private let t0 = 1_792_300_000_000
private let min = StudyClock.minute
private let pomodoro = TimerMode.builtin[0]

private func running(at t: Int = t0) -> TimerState {
    var s = TimerState(modeId: pomodoro.id)
    s.configure(TimerSetup(subjectId: "nem", topic: "Slovíčka"))
    s.start(now: t, mode: pomodoro)
    return s
}

private func sessions(_ events: [TimerEvent]) -> [TimerSession] {
    events.compactMap { if case .session(let s) = $0 { s } else { nil } }
}

@Suite("Časovač – pauzy")
struct TimerPauseTests {
    @Test("Úseky práce: pauza je mezera, běžící úsek končí teď")
    func spans() {
        var s = running()
        s.pause(now: t0 + 10 * min)
        #expect(s.workSpans(at: t0 + 60 * min) == [WorkSpan(start: t0, end: t0 + 10 * min)])
        s.resume(now: t0 + 30 * min)
        #expect(s.workSpans(at: t0 + 35 * min) == [WorkSpan(start: t0, end: t0 + 10 * min), WorkSpan(start: t0 + 30 * min, end: t0 + 35 * min)])
        #expect(s.lastActivity(at: t0 + 35 * min) == t0 + 35 * min)
    }

    @Test("Ukončit po pauze přes noc: záznam končí chvílí pozastavení")
    func stopAfterNight() {
        var s = running()
        s.pause(now: t0 + 22 * min)
        let saved = sessions(s.stop(now: t0 + 16 * 60 * min, rules: TimerRules()))
        #expect(saved.first?.start == t0)
        #expect(saved.first?.end == t0 + 22 * min)
        #expect(saved.first?.durationSec == 22 * 60)
    }

    @Test("Hotovo v pauze: záznam končí pozastavením, pauza mezi bloky začne teď")
    func finishWhilePaused() {
        var s = running()
        s.pause(now: t0 + 20 * min)
        let saved = sessions(s.finishWork(now: t0 + 50 * min, mode: pomodoro, rules: TimerRules()))
        #expect(saved.first?.end == t0 + 20 * min)
        #expect(s.phase == .short && s.segmentStart == t0 + 50 * min)
        #expect(s.spans == nil && s.pausedAt == nil)
    }

    @Test("Pozastavený déle než limit: uloží se do pozastavení a série skončí; 0 = nikdy")
    func pauseLimit() {
        let rules = TimerRules(pauseLimitMin: 120)
        var s = running()
        s.pause(now: t0 + 22 * min)
        #expect(s.nextDeadline(now: t0 + 30 * min, rules: rules) == t0 + 142 * min)
        #expect(s.advance(now: t0 + 141 * min, mode: pomodoro, rules: rules).isEmpty)
        let events = s.advance(now: t0 + 14 * 60 * min, mode: pomodoro, rules: rules)
        #expect(sessions(events).first?.end == t0 + 22 * min)
        #expect(events.last == .pauseExpired(minutes: 14 * 60 - 22, saved: true))
        #expect(s.status == .idle && s.workStartedAt == nil)

        var never = running()
        never.pause(now: t0 + 22 * min)
        #expect(never.nextDeadline(now: t0 + 30 * min, rules: TimerRules()) == nil)
        #expect(never.advance(now: t0 + 14 * 60 * min, mode: pomodoro, rules: TimerRules()).isEmpty)
        #expect(never.status == .paused)
    }

    @Test("Krátký pozastavený blok se po limitu neuloží, ale skončí")
    func pauseLimitTooShort() {
        var s = running()
        s.pause(now: t0 + 30_000)
        let events = s.advance(now: t0 + 3 * 60 * min, mode: pomodoro, rules: TimerRules(pauseLimitMin: 120))
        #expect(events == [.pauseExpired(minutes: 179, saved: false)])
        #expect(s.status == .idle)
    }

    @Test("Stav ze starší verze (bez úseků): pozastavení se odhadne z odpracovaného času")
    func legacyState() throws {
        var s = running()
        s.pause(now: t0 + 22 * min)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json["spans"] = nil
        json["pausedAt"] = nil
        let old = try JSONDecoder().decode(TimerState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.spans == nil)
        #expect(old.workSpans(at: t0 + 600 * min) == [WorkSpan(start: t0, end: t0 + 22 * min)])
        var stopped = old
        #expect(sessions(stopped.stop(now: t0 + 600 * min, rules: TimerRules())).first?.end == t0 + 22 * min)
    }
}
