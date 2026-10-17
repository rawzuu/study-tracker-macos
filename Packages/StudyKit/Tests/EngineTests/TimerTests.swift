import Core
import Foundation
import Testing
@testable import Engine

// Chování podle `src/features/timer/TimerContext.tsx` na webu.
private let t0 = 1_792_300_000_000
private let min = StudyClock.minute
private let pomodoro = TimerMode.builtin[0]
private let flowtime = TimerMode.find("flowtime", presets: [])
private let stopwatch = TimerMode.find("stopwatch", presets: [])

private func running(_ mode: TimerMode = pomodoro, at t: Int = t0) -> TimerState {
    var s = TimerState(modeId: mode.id)
    s.configure(TimerSetup(subjectId: "anat", topic: " Lebka "))
    s.start(now: t, mode: mode)
    return s
}

private func sessions(_ events: [TimerEvent]) -> [TimerSession] {
    events.compactMap { if case .session(let s) = $0 { s } else { nil } }
}

@Suite("Časovač")
struct TimerTests {
    @Test("Bez předmětu nejde začít")
    func needsSubject() {
        var s = TimerState(modeId: "pomodoro")
        s.start(now: t0, mode: pomodoro)
        #expect(s.status == .idle)
    }

    @Test("Uběhlý čas se počítá z časových značek, pauza ho zastaví")
    func elapsedFromTimestamps() {
        var s = running()
        #expect(s.remaining(at: t0 + 10 * min) == 15 * min)
        s.pause(now: t0 + 10 * min)
        #expect(s.elapsed(at: t0 + 60 * min) == 10 * min)
        s.resume(now: t0 + 60 * min)
        #expect(s.elapsed(at: t0 + 65 * min) == 15 * min)
        #expect(s.progress(at: t0 + 65 * min) == 0.6)
        #expect(s.nextDeadline(now: t0 + 65 * min, rules: TimerRules()) == t0 + 75 * min)
    }

    @Test("Doběhnutý blok se uloží s délkou režimu a začne pauza")
    func naturalWorkEnd() {
        var s = running()
        #expect(s.advance(now: t0 + 24 * min, mode: pomodoro, rules: TimerRules()).isEmpty)
        let events = s.advance(now: t0 + 25 * min + 400, mode: pomodoro, rules: TimerRules())
        let saved = sessions(events)
        #expect(saved == [TimerSession(id: "timer-\(t0)", subjectId: "anat", topic: "Lebka", start: t0, end: t0 + 25 * min,
                                       durationSec: 1500, mode: "pomodoro", interruptions: 0, planBlockId: nil)])
        #expect(events.last == .workEnded)
        #expect(s.status == .running && s.phase == .short && s.round == 1)
        #expect(s.segmentStart == t0 + 25 * min && s.phaseDurationMs == 5 * min)
        // druhé doběhnutí téže fáze nic neuloží
        #expect(sessions(s.advance(now: t0 + 26 * min, mode: pomodoro, rules: TimerRules())).isEmpty)
    }

    @Test("Bez automatické pauzy čeká mezi bloky")
    func readyBetweenBlocks() {
        var s = running()
        _ = s.advance(now: t0 + 25 * min, mode: pomodoro, rules: TimerRules(autoStartBreaks: false))
        #expect(s.status == .ready && s.phase == .short && s.readyAt == t0 + 25 * min)
        s.start(now: t0 + 27 * min, mode: pomodoro)
        #expect(s.status == .running && s.workStartedAt == nil && s.segmentStart == t0 + 27 * min)
    }

    @Test("Po 4 kolech Pomodora dlouhá pauza")
    func longBreak() {
        var s = running()
        var t = t0
        for round in 1...4 {
            t += 25 * min
            _ = s.advance(now: t, mode: pomodoro, rules: TimerRules())
            #expect(s.round == round)
            #expect(s.phase == (round == 4 ? .long : .short))
            #expect(s.phaseDurationMs == (round == 4 ? 20 : 5) * min)
            t += s.phaseDurationMs!
            _ = s.advance(now: t, mode: pomodoro, rules: TimerRules())
            #expect(s.status == .ready && s.phase == .work)
            s.start(now: t, mode: pomodoro)
        }
    }

    @Test("Konec pauzy: blok se sám spustí jen hned, ne po dlouhé nepřítomnosti")
    func autoStartWork() {
        let rules = TimerRules(autoStartWork: true)
        var s = running()
        _ = s.advance(now: t0 + 30 * min + 30_000, mode: pomodoro, rules: rules)
        #expect(s.status == .running && s.phase == .work && s.workStartedAt == t0 + 30 * min)

        var away = running()
        let events = away.advance(now: t0 + 31 * min, mode: pomodoro, rules: rules)
        #expect(events.contains(.breakEnded))
        #expect(away.status == .ready && away.phase == .work && away.readyAt == t0 + 30 * min)
    }

    @Test("Po uspání Macu se dožene konec bloku i pauzy a čekající série se ukončí")
    func catchUpAfterSleep() {
        var s = running()
        let events = s.advance(now: t0 + 8 * 60 * min, mode: pomodoro, rules: TimerRules(autoStartWork: true))
        #expect(sessions(events).count == 1)
        #expect(events.contains(.workEnded) && events.contains(.breakEnded))
        #expect(s.status == .idle && s.round == 0)
    }

    @Test("Série čekající déle než nastavenou dobu se ukončí; 0 = nikdy")
    func seriesTimeout() {
        var s = running()
        let rules = TimerRules(autoStartBreaks: false)
        _ = s.advance(now: t0 + 25 * min, mode: pomodoro, rules: rules)
        #expect(s.nextDeadline(now: t0 + 25 * min, rules: rules) == t0 + 45 * min)
        _ = s.advance(now: t0 + 44 * min, mode: pomodoro, rules: rules)
        #expect(s.status == .ready)
        _ = s.advance(now: t0 + 45 * min, mode: pomodoro, rules: rules)
        #expect(s.status == .idle)

        var never = running()
        let noTimeout = TimerRules(autoStartBreaks: false, seriesTimeoutMin: 0)
        _ = never.advance(now: t0 + 25 * min, mode: pomodoro, rules: noTimeout)
        _ = never.advance(now: t0 + 999 * min, mode: pomodoro, rules: noTimeout)
        #expect(never.status == .ready && never.nextDeadline(now: t0, rules: noTimeout) == nil)
    }

    @Test("Hotovo: uloží skutečně odučený čas, krátký blok se neuloží a ohlásí")
    func finishWork() {
        var s = running()
        s.addInterruption()
        let events = s.finishWork(now: t0 + 12 * min + 700, mode: pomodoro, rules: TimerRules())
        #expect(sessions(events).first?.durationSec == 721)
        #expect(sessions(events).first?.interruptions == 1)
        #expect(!events.contains(.workEnded))
        #expect(s.phase == .short && s.interruptions == 0)

        var short = running()
        #expect(short.finishWork(now: t0 + 59_000, mode: pomodoro, rules: TimerRules()) == [.tooShort])
        #expect(short.phase == .short)
        // Doběhnutý blok kratší než minimum (režim 30 s) se neuloží, ale ani neohlásí – jako na webu.
        let tiny = TimerMode(preset: TimerPreset(raw: ["id": "p", "name": "30 s", "workMin": 0.5, "shortBreakMin": 1, "longBreakMin": 1, "roundsBeforeLong": 4]))
        var natural = running(tiny)
        #expect(natural.advance(now: t0 + 30_000, mode: tiny, rules: TimerRules()) == [.workEnded])
    }

    @Test("Ukončit: v bloku uloží a ukončí sérii, v pauze jen ukončí")
    func stop() {
        var s = running()
        #expect(sessions(s.stop(now: t0 + 10 * min, rules: TimerRules())).first?.durationSec == 600)
        #expect(s.status == .idle && s.round == 0 && s.subjectId == "anat")

        var inBreak = running()
        _ = inBreak.advance(now: t0 + 25 * min, mode: pomodoro, rules: TimerRules())
        #expect(inBreak.stop(now: t0 + 27 * min, rules: TimerRules()).isEmpty)
        #expect(inBreak.status == .idle)
    }

    @Test("Přeskočit pauzu, zahodit blok")
    func skipAndDiscard() {
        var s = running()
        _ = s.advance(now: t0 + 25 * min, mode: pomodoro, rules: TimerRules())
        #expect(s.skip(now: t0 + 26 * min, mode: pomodoro, rules: TimerRules()).isEmpty)
        #expect(s.status == .ready && s.phase == .work && s.phaseDurationMs == 25 * min)

        var d = running()
        d.discard()
        #expect(d.status == .idle && d.workStartedAt == nil)
    }

    @Test("Flowtime: pauza ≈ pětina učení, aspoň minuta")
    func flowtimeBreak() {
        var s = running(flowtime)
        #expect(s.remaining(at: t0) == nil)
        _ = s.finishWork(now: t0 + 47 * min, mode: flowtime, rules: TimerRules())
        #expect(s.phaseDurationMs == 9 * min)

        var quick = running(flowtime)
        _ = quick.finishWork(now: t0 + 2 * min, mode: flowtime, rules: TimerRules())
        #expect(quick.phaseDurationMs == min)
    }

    @Test("Stopky: po uložení zpět do klidu, bez pauzy")
    func stopwatchEnds() {
        var s = running(stopwatch)
        #expect(sessions(s.finishWork(now: t0 + 40 * min, mode: stopwatch, rules: TimerRules())).count == 1)
        #expect(s.status == .idle && s.phase == .work)
    }

    @Test("Nastavení: změna režimu v klidu vynuluje kola, setup mezi bloky začne novou sérii, běžící blok nepřeruší")
    func setup() {
        var s = TimerState(modeId: "pomodoro")
        s.round = 3
        s.configure(TimerSetup(modeId: "52-17"))
        #expect(s.round == 0 && s.modeId == "52-17")

        var live = running()
        live.setup(TimerSetup(subjectId: "fyz"))
        #expect(live.subjectId == "anat")

        var ready = running()
        _ = ready.advance(now: t0 + 25 * min, mode: pomodoro, rules: TimerRules(autoStartBreaks: false))
        ready.setup(TimerSetup(subjectId: "fyz", planBlockId: "b1"))
        #expect(ready.status == .idle && ready.round == 0 && ready.subjectId == "fyz" && ready.planBlockId == "b1")
    }

    @Test("Stav přežije restart aplikace (JSON)")
    func persistence() throws {
        let s = running()
        let restored = try JSONDecoder().decode(TimerState.self, from: JSONEncoder().encode(s))
        #expect(restored == s)
        #expect(restored.remaining(at: t0 + 20 * min) == 5 * min)
    }

    @Test("Vlastní režim: popisek s čísly jako v JS, dlouhá pauza nikdy při 0 kolech")
    func presets() {
        var p = TimerPreset(raw: ["id": "p1", "name": "Vlastní", "workMin": 45, "shortBreakMin": 7.5, "longBreakMin": 20, "roundsBeforeLong": 0])
        let mode = TimerMode(preset: p)
        #expect(mode.tagline == "45 / 7.5 · dlouhá 20 min po 0 kolech")
        var s = running(mode)
        _ = s.advance(now: t0 + 45 * min, mode: mode, rules: TimerRules())
        #expect(s.phase == .short && s.phaseDurationMs == 450_000)

        p.raw["deletedAt"] = 5
        #expect(TimerMode.all(presets: [p]).count == TimerMode.builtin.count)
        #expect(TimerMode.find("p1", presets: [p]).id == "pomodoro")
    }

    @Test("Uložení: sezení a odškrtnutí bloků plánu, se kterými se kryje")
    func saveIntoDocument() throws {
        var doc = AppDocument.empty
        func block(_ id: String, _ subject: String, start: Int, minutes: Int, done: Bool = false) -> PlanBlock {
            PlanBlock(raw: ["id": .string(id), "subjectId": .string(subject), "title": "", "start": .number(Double(start)),
                            "durationMin": .number(Double(minutes)), "done": .bool(done), "note": ""])
        }
        doc.upsert([
            block("linked", "jiny", start: t0 + 300 * min, minutes: 60),
            block("prekryv", "anat", start: t0 + 10 * min, minutes: 60), // 15 min překryvu
            block("kratky", "anat", start: t0 + 20 * min, minutes: 10), // 5 min z 10 = polovina
            block("malo", "anat", start: t0 + 21 * min, minutes: 60), // jen 4 min
            block("hotovy", "anat", start: t0, minutes: 25, done: true),
            block("cizi", "fyz", start: t0, minutes: 25),
        ], now: 1)
        let session = TimerSession(id: "timer-\(t0)", subjectId: "anat", topic: "Lebka", start: t0, end: t0 + 25 * min,
                                   durationSec: 1500, mode: "pomodoro", interruptions: 2, planBlockId: "linked")
        doc.saveTimerSession(session, now: 99)

        let saved = try #require(doc.record(Session.self, id: "timer-\(t0)"))
        #expect(saved.raw.keys == ["id", "subjectId", "topic", "start", "end", "durationSec", "mode", "interruptions", "note", "createdAt", "updatedAt"])
        #expect(saved.topicId == nil && saved.durationSec == 1500 && saved.interruptions == 2)
        let done = Set(doc.alive(PlanBlock.self).filter(\.done).map(\.id))
        #expect(done == ["linked", "prekryv", "kratky", "hotovy"])
        #expect(doc.record(PlanBlock.self, id: "hotovy")?.updatedAt == 1)
    }
}
