import Core

/// Položka týdenního kalendáře (`CalItem` na webu): blok plánu (obrys), odučené sezení (plná barva),
/// právě běžící blok nebo hodina z rozvrhu (šedě).
public struct CalendarItem: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case block(id: String)
        case session(id: String)
        /// Blok, který právě běží na časovači.
        case live
        case lecture(timetableId: String, key: String)
    }

    /// Skutečný začátek a konec položky, která je rozdělená přes půlnoc.
    public struct Span: Hashable, Sendable {
        public let start: Int
        public let end: Int
    }

    public var id: String
    public var source: Source
    public var subjectId: String
    public var start: Int
    public var end: Int
    public var title: String
    public var span: Span?

    public init(id: String, source: Source, subjectId: String, start: Int, end: Int, title: String, span: Span? = nil) {
        self.id = id
        self.source = source
        self.subjectId = subjectId
        self.start = start
        self.end = end
        self.title = title
        self.span = span
    }

    public var isPlan: Bool {
        if case .block = source { true } else { false }
    }

    /// Začátek a konec celé položky (i když je rozdělená přes půlnoc).
    public var fullStart: Int { span?.start ?? start }
    public var fullEnd: Int { span?.end ?? end }
    /// Poslední kus položky – jen za ten jde blok natáhnout.
    public var isLastPart: Bool { span == nil || end == span?.end }
}

/// Rozložení týdenního kalendáře (`PlannerPage` na webu).
public enum CalendarLayout {
    /// Mřížka začíná v 6:00, pokud nic nezačíná dřív (třeba učení po půlnoci).
    public static let defaultFirstHour = 6
    /// Položka je v mřížce vysoká aspoň jako 20 minut – kvůli tomu se může překrývat se sousední.
    static let minimumItemMs = 20 * StudyClock.minute

    public struct Lane: Hashable, Sendable {
        public let lane: Int
        public let lanes: Int
    }

    /// Položka přes půlnoc se kreslí ve dvou dnech – jinak by přetekla pod mřížku a ráno by chyběla.
    public static func splitAtMidnight(_ item: CalendarItem, clock: StudyClock) -> [CalendarItem] {
        let midnight = clock.addDays(clock.startOfDay(item.start), 1)
        guard item.end > midnight else { return [item] }
        let span = CalendarItem.Span(start: item.start, end: item.end)
        var first = item, second = item
        first.end = midnight
        first.span = span
        second.id = item.id + "~2"
        second.start = midnight
        second.span = span
        return [first, second]
    }

    /// Rozdělení překrývajících se položek jednoho dne do sloupců: skupina navzájem se překrývajících
    /// položek dostane tolik sloupců, kolik jich najednou potřebuje.
    public static func lanes(_ items: [CalendarItem]) -> [String: Lane] {
        // Na webu `a.start - b.start || (a.kind === 'plan' ? -1 : 1)` – bloky plánu dřív než sezení
        let sorted = JS.sort(items) { a, b in a.start != b.start ? (a.start < b.start ? -1 : 1) : a.isPlan ? -1 : 1 }
        var out: [String: Lane] = [:]
        var cluster: [String] = []
        var laneEnds: [Int] = []
        var clusterEnd = Int.min
        func flush() {
            for id in cluster { out[id] = Lane(lane: out[id]!.lane, lanes: laneEnds.count) }
            cluster = []
            laneEnds = []
        }
        for item in sorted {
            let end = max(item.end, item.start + minimumItemMs)
            if item.start >= clusterEnd {
                flush()
                clusterEnd = Int.min
            }
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 <= item.start }) {
                lane = free
                laneEnds[free] = end
            } else {
                lane = laneEnds.count
                laneEnds.append(end)
            }
            out[item.id] = Lane(lane: lane, lanes: 1)
            cluster.append(item.id)
            clusterEnd = max(clusterEnd, end)
        }
        flush()
        return out
    }

    /// První hodina mřížky: 6:00, nebo dřív, když něco začíná dřív.
    public static func firstHour(_ items: [CalendarItem], clock: StudyClock) -> Int {
        items.reduce(defaultFirstHour) { min($0, clock.calendar.component(.hour, from: clock.date($1.start))) }
    }
}

extension PlanMatch {
    /// Je k bloku už zapsané sezení (třeba z časovače)? Pak „Hotovo“ nic nezapisuje znovu.
    public static func hasSession(_ sessions: [Session], for block: PlanBlock) -> Bool {
        sessions.contains { !$0.isDeleted && $0.subjectId == block.subjectId && covers(block, start: $0.start, end: $0.end) }
    }

    /// Předvyplnění zápisu z bloku („Hotovo“): kdy začal a kolik z něj do teď mohlo proběhnout
    /// (`fromBlock` na webu). Blok, který ještě nezačal, se zapíše jako právě skončený.
    public static func loggedSpan(of block: PlanBlock, now: Int) -> (start: Int, minutes: Int) {
        if block.start >= now { return (now - block.durationMin * StudyClock.minute, block.durationMin) }
        let ran = Int(JS.round(Double(now - block.start) / Double(StudyClock.minute)))
        return (block.start, max(1, min(block.durationMin, ran)))
    }
}
