import Engine
import Foundation

/// Co má uživatel právě před sebou: aplikace v popředí a v prohlížeči doména aktivní záložky.
public struct UsageActivity: Sendable, Hashable {
    public var bundleId: String
    public var appName: String
    /// Doména (jen v prohlížeči), jinak prázdná.
    public var host: String

    public init(bundleId: String, appName: String, host: String = "") {
        self.bundleId = bundleId
        self.appName = appName
        self.host = host
    }
}

/// Souvislý úsek jedné činnosti.
public struct UsageSegment: Sendable, Equatable {
    public var activity: UsageActivity
    public var start: Int
    public var end: Int

    public init(activity: UsageActivity, start: Int, end: Int) {
        self.activity = activity
        self.start = start
        self.end = end
    }

    /// Rozdělí úsek po hodinách místního času (graf podle hodin, přechod přes půlnoc).
    public func byHour(clock: StudyClock) -> [(day: String, hour: Int, ms: Int)] {
        var out: [(String, Int, Int)] = []
        var t = start
        while t < end {
            let hour = clock.hour(t)
            let next = min(end, max(t + 1, clock.atMinutes(clock.startOfDay(t), (hour + 1) * 60)))
            out.append((clock.dayKey(t), hour, next - t))
            t = next
        }
        return out
    }
}

/// Měření času u obrazovky z pravidelných kontrol: kdo se ptá, předá, co je v popředí (nebo `nil`, když
/// uživatel u Macu není), a dostane uzavřené úseky k uložení.
public struct UsageMeter: Sendable {
    /// Delší mezera mezi kontrolami (uspání, zastavený proces) se nepočítá.
    public var maxGap: Int

    private(set) var open: (activity: UsageActivity, start: Int)?
    private(set) var lastSeen: Int?

    public init(maxGap: Int = 60_000) {
        self.maxGap = maxGap
    }

    /// Kontrola v okamžiku `t`. Když uživatel odešel, předá se `nil` a `t` = okamžik poslední aktivity.
    public mutating func update(_ activity: UsageActivity?, at t: Int) -> [UsageSegment] {
        var out: [UsageSegment] = []
        if let open, let lastSeen, t - lastSeen > maxGap {
            // Mezera bez kontrol: úsek končí poslední kontrolou.
            out += close(open, at: lastSeen)
            self.open = nil
        }
        if let open, open.activity != activity {
            out += close(open, at: t)
            self.open = nil
        }
        if open == nil, let activity { open = (activity, t) }
        lastSeen = max(lastSeen ?? t, t)
        return out
    }

    /// Uzavře rozpracovaný úsek (ukončení Strážce, uložení průběžně).
    public mutating func flush(at t: Int) -> [UsageSegment] {
        guard let open else { return [] }
        let out = close(open, at: t)
        self.open = (open.activity, max(open.start, t))
        return out
    }

    private func close(_ open: (activity: UsageActivity, start: Int), at t: Int) -> [UsageSegment] {
        t > open.start ? [UsageSegment(activity: open.activity, start: open.start, end: t)] : []
    }
}
