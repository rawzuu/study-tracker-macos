import Engine

/// Co ukazuje kruh časovače (`TimerRing` na webu): dílky po minutách, stupnice, čas uprostřed.
/// Odpočet = délka fáze, stopky a Flowtime = jedna hodina dokola.
public struct TimerRingModel: Equatable {
    public enum Tone: Equatable, Sendable { case work, rest, paused, idle }
    public enum Segment: Equatable, Sendable { case off, lit, now }

    public let phaseLabel: String
    public let time: String
    public let modeName: String
    public let tone: Tone
    public let segments: [Segment]
    /// Popisky stupnice: minuta a její podíl obvodu (0 = nahoře).
    public let labels: [(minute: Int, fraction: Double)]
    /// Kolečka kol do dlouhé pauzy (`nil` = režim je neukazuje).
    public let rounds: (total: Int, done: Int)?

    public init(state: TimerState, mode: TimerMode, now: Int) {
        let idle = state.status == .idle
        let elapsed = state.elapsed(at: now)
        let remaining = state.remaining(at: now)
        let countUp = idle ? mode.workMin == nil : remaining == nil
        let p = idle ? 0 : countUp ? Double(elapsed % 3_600_000) / 3_600_000 : state.progress(at: now)
        let idleMs = Int(((mode.workMin ?? 0) * 60_000).rounded())
        time = idle ? Format.clock(ms: idleMs) : countUp ? Format.clock(ms: elapsed) : Format.clock(ms: remaining ?? 0)
        phaseLabel = idle ? "Připraveno" : state.phase == .work ? "Učení" : state.phase == .long ? "Dlouhá pauza" : "Pauza"
        modeName = mode.name
        tone = idle ? .idle : state.status == .paused ? .paused : state.phase == .work ? .work : .rest

        let phaseMs = idle ? idleMs : (state.phaseDurationMs ?? elapsed + (remaining ?? 0))
        let totalMin = countUp ? 60 : max(1, Int((Double(phaseMs) / 60_000).rounded(.toNearestOrAwayFromZero)))
        // Jeden dílek = minuta; u krátkých pauz půl minuty, u dlouhých bloků víc minut (max. ~60 dílků).
        let perSeg = totalMin < 10 ? 0.5 : totalMin > 60 ? (Double(totalMin) / 60).rounded(.up) : 1
        let n = max(1, Int((Double(totalMin) / perSeg).rounded(.toNearestOrAwayFromZero)))
        let labelStep = totalMin <= 10 ? 1 : totalMin <= 30 ? 5 : totalMin <= 60 ? (countUp ? 15 : 10) : totalMin <= 120 ? 15 : 30
        let done = p * Double(n)
        let whole = Int(done.rounded(.down))
        segments = (0..<n).map { i in
            if i < whole { return .lit }
            if i == whole && done > 0 && done < Double(n) { return .now }
            return .off
        }
        labels = stride(from: 0, to: totalMin, by: labelStep).map { ($0, Double($0) / Double(totalMin)) }

        if mode.showsRounds {
            let total = mode.roundsBeforeLong
            rounds = (total, state.phase == .long ? total : state.round % total)
        } else {
            rounds = nil
        }
    }

    public static func == (a: TimerRingModel, b: TimerRingModel) -> Bool {
        a.phaseLabel == b.phaseLabel && a.time == b.time && a.modeName == b.modeName && a.tone == b.tone && a.segments == b.segments
            && a.labels.map(\.minute) == b.labels.map(\.minute) && a.rounds?.total == b.rounds?.total && a.rounds?.done == b.rounds?.done
    }
}
