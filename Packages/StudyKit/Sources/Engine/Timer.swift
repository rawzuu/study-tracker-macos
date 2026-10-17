import Core
import Foundation

// Časovač řízený časovými značkami jako na webu (`TimerContext.tsx`): stav je jen „kdy co začalo“,
// uběhlý čas se vždy dopočítá z hodin. Je proto přesný i v pozadí, po uspání Macu i po restartu
// aplikace – a nepotřebuje tikající časovač. Všechny přechody jsou čisté funkce s explicitním `now`.

public enum TimerPhase: String, Codable, Sendable {
    case work, short, long
}

public enum TimerStatus: String, Codable, Sendable {
    /// Nic neběží.
    case idle
    case running
    case paused
    /// Mezi bloky: čeká na „Další blok“ / „Začít pauzu“.
    case ready
}

/// Stav časovače (jen na tomto Macu, jako `localStorage` `st.timer` na webu).
public struct TimerState: Codable, Sendable, Equatable {
    public var status: TimerStatus = .idle
    public var phase: TimerPhase = .work
    public var modeId: String
    public var subjectId = ""
    public var topic = ""
    /// Blok plánu, ze kterého byl časovač spuštěn – po uložení sezení se odškrtne.
    public var planBlockId: String?
    public var segmentStart: Int?
    /// Uběhlý čas fáze před posledním pozastavením (ms).
    public var accumulated = 0
    /// Délka fáze (ms); `nil` = počítá nahoru.
    public var phaseDurationMs: Int?
    public var round = 0
    public var interruptions = 0
    public var workStartedAt: Int?
    /// Od kdy čeká na další blok (kvůli automatickému ukončení série).
    public var readyAt: Int?

    public init(modeId: String) {
        self.modeId = modeId
    }

    /// Uběhlý čas aktuální fáze (ms).
    public func elapsed(at now: Int) -> Int {
        accumulated + (status == .running ? segmentStart.map { now - $0 } ?? 0 : 0)
    }

    /// Zbývající čas fáze (ms); `nil` = počítá nahoru.
    public func remaining(at now: Int) -> Int? {
        phaseDurationMs.map { max(0, $0 - elapsed(at: now)) }
    }

    /// 0–1 (u počítání nahoru 0).
    public func progress(at now: Int) -> Double {
        guard let d = phaseDurationMs, d > 0 else { return 0 }
        return min(1, Double(elapsed(at: now)) / Double(d))
    }

    /// Jde teď začít něco nového? Ano, když nic neběží – i mezi bloky, kdy je vše hotové už uložené.
    public var canSwitch: Bool { status == .idle || status == .ready }

    /// Běží (nebo stojí pozastavený) blok učení.
    public var isStudying: Bool { phase == .work && (status == .running || status == .paused) }
}

/// Pravidla časovače ze synchronizovaného nastavení.
public struct TimerRules: Sendable, Equatable {
    public var minSessionSec: Int
    public var autoStartBreaks: Bool
    public var autoStartWork: Bool
    public var flowtimeRatio: Double
    /// Po kolika minutách čekání se série ukončí (0 = nikdy).
    public var seriesTimeoutMin: Int

    public init(minSessionSec: Int = 60, autoStartBreaks: Bool = true, autoStartWork: Bool = false, flowtimeRatio: Double = 5, seriesTimeoutMin: Int = 20) {
        self.minSessionSec = minSessionSec
        self.autoStartBreaks = autoStartBreaks
        self.autoStartWork = autoStartWork
        self.flowtimeRatio = flowtimeRatio
        self.seriesTimeoutMin = seriesTimeoutMin
    }

    public init(settings s: Settings) {
        self.init(minSessionSec: s.minSessionSec, autoStartBreaks: s.autoStartBreaks, autoStartWork: s.autoStartWork,
                  flowtimeRatio: s.flowtimeRatio, seriesTimeoutMin: s.seriesTimeoutMin)
    }
}

/// Hotový blok učení k uložení jako sezení.
public struct TimerSession: Sendable, Equatable {
    public var id: String
    public var subjectId: String
    public var topic: String
    public var start: Int
    public var end: Int
    public var durationSec: Int
    public var mode: String
    public var interruptions: Int
    public var planBlockId: String?
}

/// Co se při přechodu stalo – aplikace podle toho ukládá, zvoní a upozorňuje.
public enum TimerEvent: Sendable, Equatable {
    case session(TimerSession)
    /// Blok byl kratší než nastavené minimum a neuložil se.
    case tooShort
    /// Blok práce doběhl sám (zvonek, notifikace).
    case workEnded
    /// Pauza doběhla sama.
    case breakEnded
}

/// Úprava nastavení časovače (předmět, téma, režim, blok plánu).
public struct TimerSetup: Sendable, Equatable {
    public var subjectId: String?
    public var topic: String?
    public var modeId: String?
    public var planBlockId: String?

    public init(subjectId: String? = nil, topic: String? = nil, modeId: String? = nil, planBlockId: String? = nil) {
        self.subjectId = subjectId
        self.topic = topic
        self.modeId = modeId
        self.planBlockId = planBlockId
    }
}

extension TimerState {
    // MARK: - Nastavení

    /// Ruční úprava (`configure`). Změna režimu v klidu začne kola od nuly.
    public mutating func configure(_ patch: TimerSetup) {
        if let modeId = patch.modeId {
            if modeId != self.modeId, status == .idle { round = 0 }
            self.modeId = modeId
        }
        if let subjectId = patch.subjectId { self.subjectId = subjectId }
        if let topic = patch.topic { self.topic = topic }
        if let planBlockId = patch.planBlockId { self.planBlockId = planBlockId }
    }

    /// Nový blok z plánu nebo odkazu (`setup`): mezi bloky nejdřív ukončí sérii, běžící blok nepřeruší.
    public mutating func setup(_ patch: TimerSetup) {
        guard canSwitch else { return }
        if status == .ready { reset() }
        configure(patch)
    }

    // MARK: - Ovládání

    /// „Začít učení“ / „Další blok“ / „Začít pauzu“.
    public mutating func start(now: Int, mode: TimerMode) {
        switch status {
        case .ready:
            status = .running
            readyAt = nil
            segmentStart = now
            accumulated = 0
            workStartedAt = phase == .work ? now : nil
        case .idle:
            guard !subjectId.isEmpty else { return }
            status = .running
            phase = .work
            segmentStart = now
            accumulated = 0
            phaseDurationMs = mode.workDurationMs
            interruptions = 0
            workStartedAt = now
        case .running, .paused:
            return
        }
    }

    public mutating func pause(now: Int) {
        guard status == .running else { return }
        accumulated = elapsed(at: now)
        status = .paused
        segmentStart = nil
    }

    public mutating func resume(now: Int) {
        guard status == .paused else { return }
        status = .running
        segmentStart = now
    }

    /// „Hotovo“ / „Na pauzu“: uloží blok a přejde na pauzu.
    public mutating func finishWork(now: Int, mode: TimerMode, rules: TimerRules) -> [TimerEvent] {
        guard isStudying else { return [] }
        return endWork(at: now, natural: false, mode: mode, rules: rules)
    }

    /// „Ukončit“: uloží rozpracovaný blok a ukončí sérii.
    public mutating func stop(now: Int, rules: TimerRules) -> [TimerEvent] {
        var events: [TimerEvent] = []
        if isStudying { events = saved(endAt: now, elapsed: cappedElapsed(at: now), rules: rules) }
        reset()
        return events
    }

    /// Zahodí aktuální blok bez uložení.
    public mutating func discard() {
        reset()
    }

    /// „Přeskočit“ / „Bez pauzy“.
    public mutating func skip(now: Int, mode: TimerMode, rules: TimerRules) -> [TimerEvent] {
        guard phase != .work else { return [] }
        return endBreak(at: now, natural: false, now: now, mode: mode, rules: rules)
    }

    public mutating func addInterruption() {
        interruptions += 1
    }

    // MARK: - Běh času

    /// Dožene vše, co mělo mezitím proběhnout: konec bloku, konec pauzy, ukončení čekající série.
    /// Po dlouhé nepřítomnosti (uspaný Mac, zavřená aplikace) se další blok sám nespustí.
    public mutating func advance(now: Int, mode: TimerMode, rules: TimerRules) -> [TimerEvent] {
        var events: [TimerEvent] = []
        for _ in 0..<64 {
            guard status == .running, let duration = phaseDurationMs, let segmentStart, elapsed(at: now) >= duration else { break }
            let endAt = segmentStart + (duration - accumulated)
            events += phase == .work
                ? endWork(at: endAt, natural: true, mode: mode, rules: rules)
                : endBreak(at: endAt, natural: true, now: now, mode: mode, rules: rules)
        }
        if status == .ready, rules.seriesTimeoutMin > 0 {
            let since = readyAt ?? now
            readyAt = since
            if now >= since + rules.seriesTimeoutMin * StudyClock.minute { reset() }
        }
        return events
    }

    /// Kdy má proběhnout další automatický přechod (konec fáze nebo ukončení série); `nil` = žádný.
    public func nextDeadline(now: Int, rules: TimerRules) -> Int? {
        switch status {
        case .running:
            guard let duration = phaseDurationMs, let segmentStart else { return nil }
            return segmentStart + (duration - accumulated)
        case .ready:
            guard rules.seriesTimeoutMin > 0 else { return nil }
            return (readyAt ?? now) + rules.seriesTimeoutMin * StudyClock.minute
        case .idle, .paused:
            return nil
        }
    }

    // MARK: - Přechody

    private func cappedElapsed(at t: Int) -> Int {
        min(elapsed(at: t), phaseDurationMs ?? .max)
    }

    /// Uložení bloku (`saveSession`): bez předmětu nebo pod minimem se neukládá.
    private func saved(endAt: Int, elapsed: Int, rules: TimerRules) -> [TimerEvent] {
        guard !subjectId.isEmpty else { return [] }
        guard Double(elapsed) / 1000 >= Double(rules.minSessionSec) else { return [.tooShort] }
        // Id odvozené od začátku bloku: když se blok dokončí dvakrát, uloží se jen jednou.
        let id = workStartedAt.map { "timer-\($0)" } ?? Session.newID()
        return [.session(TimerSession(
            id: id, subjectId: subjectId, topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
            start: workStartedAt ?? endAt - elapsed, end: endAt,
            durationSec: Int((Double(elapsed) / 1000).rounded(.toNearestOrAwayFromZero)),
            mode: modeId, interruptions: interruptions, planBlockId: planBlockId
        ))]
    }

    private mutating func endWork(at endAt: Int, natural: Bool, mode: TimerMode, rules: TimerRules) -> [TimerEvent] {
        let elapsed = cappedElapsed(at: endAt)
        var events = saved(endAt: endAt, elapsed: elapsed, rules: rules)
        // Krátký blok hlásí jen ruční ukončení (jako na webu); doběhnutý blok má délku režimu.
        if natural { events = events.filter { $0 != .tooShort } + [.workEnded] }
        if mode.kind == .stopwatch {
            status = .idle
            phase = .work
            segmentStart = nil
            accumulated = 0
            phaseDurationMs = nil
            interruptions = 0
            workStartedAt = nil
            planBlockId = nil
            return events
        }
        let next = round + 1
        let breakMs: Int
        if mode.kind == .flowtime {
            let minutes = (Double(elapsed) / rules.flowtimeRatio / Double(StudyClock.minute)).rounded(.toNearestOrAwayFromZero)
            breakMs = max(StudyClock.minute, Int(minutes) * StudyClock.minute)
            phase = .short
        } else if mode.roundsBeforeLong > 0, next % mode.roundsBeforeLong == 0 {
            breakMs = Int((mode.longBreakMin * Double(StudyClock.minute)).rounded())
            phase = .long
        } else {
            breakMs = Int((mode.shortBreakMin * Double(StudyClock.minute)).rounded())
            phase = .short
        }
        round = next
        status = rules.autoStartBreaks ? .running : .ready
        readyAt = rules.autoStartBreaks ? nil : endAt
        segmentStart = rules.autoStartBreaks ? endAt : nil
        accumulated = 0
        phaseDurationMs = breakMs
        interruptions = 0
        workStartedAt = nil
        planBlockId = nil
        return events
    }

    private mutating func endBreak(at endAt: Int, natural: Bool, now: Int, mode: TimerMode, rules: TimerRules) -> [TimerEvent] {
        // Když pauza skončila dávno (zavřená aplikace, uspaný Mac), další blok se sám nespustí –
        // jinak by se za dobu nepřítomnosti uložila vymyšlená sezení.
        let auto = rules.autoStartWork && (!natural || now - endAt < StudyClock.minute)
        phase = .work
        status = auto ? .running : .ready
        readyAt = auto ? nil : endAt
        segmentStart = auto ? endAt : nil
        accumulated = 0
        phaseDurationMs = mode.workDurationMs
        interruptions = 0
        workStartedAt = auto ? endAt : nil
        return natural ? [.breakEnded] : []
    }

    private mutating func reset() {
        status = .idle
        phase = .work
        segmentStart = nil
        accumulated = 0
        phaseDurationMs = nil
        round = 0
        interruptions = 0
        workStartedAt = nil
        planBlockId = nil
        readyAt = nil
    }
}

// MARK: - Uložení do dat

/// Bloky plánu, které odpovídají odučenému sezení (`src/features/planner/match.ts`).
public enum PlanMatch {
    /// Sezení a blok se kryjí: aspoň 15 minut, u krátkého bloku aspoň jeho polovina.
    public static func covers(_ b: PlanBlock, start: Int, end: Int) -> Bool {
        let blockEnd = b.start + b.durationMin * StudyClock.minute
        let overlap = min(end, blockEnd) - max(start, b.start)
        return Double(overlap) >= min(Double(15 * StudyClock.minute), Double(b.durationMin * StudyClock.minute) / 2)
    }

    /// Neodškrtnuté bloky stejného předmětu, se kterými se sezení časově kryje.
    public static func blocks(_ blocks: [PlanBlock], subjectId: String, start: Int, end: Int) -> [PlanBlock] {
        blocks.filter { !$0.isDeleted && !$0.done && $0.subjectId == subjectId && covers($0, start: start, end: end) }
    }
}

extension AppDocument {
    /// Uloží blok z časovače jako sezení a odškrtne blok plánu, ze kterého byl spuštěn,
    /// i všechny naplánované bloky, se kterými se kryje. Téma je jen text sezení – opakování na Macu není.
    public mutating func saveTimerSession(_ s: TimerSession, now: Int) {
        upsert(Session(raw: [
            "id": .string(s.id), "subjectId": .string(s.subjectId), "topic": .string(s.topic),
            "start": .number(Double(s.start)), "end": .number(Double(s.end)), "durationSec": .number(Double(s.durationSec)),
            "mode": .string(s.mode), "interruptions": .number(Double(s.interruptions)), "note": "",
        ]), now: now)
        let plan = records(PlanBlock.self)
        let linked = plan.filter { $0.id == s.planBlockId && !$0.done }
        let matched = PlanMatch.blocks(plan, subjectId: s.subjectId, start: s.start, end: s.end).filter { $0.id != s.planBlockId }
        let done = (linked + matched).map { b -> PlanBlock in
            var b = b
            b.done = true
            return b
        }
        if !done.isEmpty { upsert(done, now: now) }
    }
}
