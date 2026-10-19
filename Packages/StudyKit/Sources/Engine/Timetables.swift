import Core
import Foundation

/// Hodina z rozvrhu, jak se ukáže v kalendáři.
public struct Lecture: Hashable, Sendable {
    public let event: TimetableEvent
    public let timetableId: String
}

/// Rozvrh (`src/lib/timetable.ts` na webu): hodiny v týdnu, náhled změn při nové verzi, přehled řad.
/// Přiřazení řady k předmětu slouží jen opakování po přednášce, které na Macu není – zůstává v datech pro web.
public enum Timetables {
    /// Aktivní hodiny ze všech rozvrhů v intervalu `[from, to)` – bez skrytých řad a odpadlých termínů.
    public static func lectures(_ doc: AppDocument, from: Int, to: Int) -> [Lecture] {
        var out: [Lecture] = []
        for tt in doc.alive(Timetable.self) {
            let hidden = Set(tt.hiddenSeries)
            let skipped = Set(tt.skipped)
            for e in tt.events where e.end > from && e.start < to && !hidden.contains(e.series) && !skipped.contains(e.key) {
                out.append(Lecture(event: e, timetableId: tt.id))
            }
        }
        return out.sorted { $0.event.start < $1.event.start }
    }

    /// Události z jiných kalendářů bez hodin, které jsou i v rozvrhu (stejný začátek i konec na minutu):
    /// výuku ukáže rozvrh a jde v něm upravit. Schovají se i události k odpadlé hodině nebo skryté řadě,
    /// aby se jejich čas opravdu uvolnil, i když v Apple Kalendáři zůstaly.
    public static func withoutLectures(_ events: [ExternalBusy], _ doc: AppDocument) -> [ExternalBusy] {
        guard let from = events.map(\.start).min(), let to = events.map(\.end).max() else { return events }
        let m = StudyClock.minute
        var lectures = Set<[Int]>()
        for tt in doc.alive(Timetable.self) {
            for e in tt.events where e.end >= from && e.start <= to { lectures.insert([e.start / m, e.end / m]) }
        }
        return lectures.isEmpty ? events : events.filter { !lectures.contains([$0.start / m, $0.end / m]) }
    }

    /// Co se změní, když starý rozvrh nahradí nový (porovnávají se jen budoucí termíny).
    public struct Diff: Equatable, Sendable {
        public let added: Int
        public let removed: Int
        public let unchanged: Int
        public let addedSeries: [String]
        public let removedSeries: [String]
    }

    public static func diff(old: [TimetableEvent], next: [TimetableEvent], now: Int) -> Diff {
        let oldFuture = old.filter { $0.end > now }
        let nextFuture = next.filter { $0.end > now }
        let id = { (e: TimetableEvent) in "\(e.key)|\(e.end)" }
        let oldKeys = Set(oldFuture.map(id))
        let nextKeys = Set(nextFuture.map(id))
        let oldSeries = orderedUnique(oldFuture.map(\.series))
        let nextSeries = orderedUnique(nextFuture.map(\.series))
        return Diff(
            added: nextFuture.filter { !oldKeys.contains(id($0)) }.count,
            removed: oldFuture.filter { !nextKeys.contains(id($0)) }.count,
            unchanged: nextFuture.filter { oldKeys.contains(id($0)) }.count,
            addedSeries: nextSeries.filter { !oldSeries.contains($0) },
            removedSeries: oldSeries.filter { !nextSeries.contains($0) }
        )
    }

    /// Nahradí budoucí termíny rozvrhu novým importem; proběhlé zůstanou, jak byly (některé školy
    /// exportují jen rozvrh „od dneška“). Skryté řady a odpadlé termíny zůstanou, pokud v novém
    /// rozvrhu pořád existují – uživatel je nemusí nastavovat znovu.
    public static func replacingEvents(_ tt: Timetable, with next: [TimetableEvent], now: Int) -> Timetable {
        let events = (tt.events.filter { $0.end <= now } + next.filter { $0.end > now }).sorted { $0.start < $1.start }
        let series = Set(events.map(\.series))
        let keys = Set(events.map(\.key))
        var out = tt
        out.importedAt = now
        out.events = events
        out.hiddenSeries = tt.hiddenSeries.filter { series.contains($0) }
        out.skipped = tt.skipped.filter { keys.contains($0) }
        return out
    }

    /// Řada (předmět) v rozvrhu: kdy se koná a kolik termínů zbývá.
    public struct SeriesInfo: Hashable, Sendable, Identifiable {
        public let series: String
        public let count: Int
        public let upcoming: Int
        /// „Po 09:15, St 11:00“ – nejčastější tři časy
        public let when: String
        public let hidden: Bool
        public var id: String { series }
    }

    public static func series(of tt: Timetable, now: Int, clock: StudyClock) -> [SeriesInfo] {
        var order: [String] = []
        var bySeries: [String: [TimetableEvent]] = [:]
        for e in tt.events {
            if bySeries[e.series] == nil { order.append(e.series) }
            bySeries[e.series, default: []].append(e)
        }
        let hidden = Set(tt.hiddenSeries)
        let cs = Locale(identifier: "cs_CZ")
        return order.map { series in
            let list = bySeries[series]!
            var slots: [(weekday: Int, time: String, count: Int)] = []
            for e in list {
                let weekday = clock.weekdayIndex(e.start), time = Format.time(e.start, clock: clock)
                if let i = slots.firstIndex(where: { $0.weekday == weekday && $0.time == time }) {
                    slots[i].count += 1
                } else {
                    slots.append((weekday, time, 1))
                }
            }
            let when = slots.sorted { $0.count > $1.count }
                .prefix(3)
                .sorted { $0.weekday != $1.weekday ? $0.weekday < $1.weekday : $0.time < $1.time }
                .map { "\(Format.weekdaysShort[$0.weekday]) \($0.time)" }
                .joined(separator: ", ")
            return SeriesInfo(series: series, count: list.count, upcoming: list.filter { $0.end > now }.count, when: when,
                              hidden: hidden.contains(series))
        }
        .sorted { $0.series.compare($1.series, locale: cs) == .orderedAscending }
    }

    /// Nový rozvrh z importu (pořadí klíčů jako na webu).
    public static func new(name: String, events: [TimetableEvent], now: Int) -> Timetable {
        Timetable(raw: [
            "id": .string(Timetable.newID()), "name": .string(name.jsTrimmed.isEmpty ? "Rozvrh" : name.jsTrimmed),
            "importedAt": .number(Double(now)), "events": .array(events.map { .object($0.raw) }), "hiddenSeries": [], "skipped": [],
        ])
    }

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
