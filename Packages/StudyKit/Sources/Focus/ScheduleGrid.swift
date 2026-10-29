/// Týden po půlhodinách (7 dní × 48) – rozvrh blokování jako mřížka, do které se tahem „maluje“.
/// Převádí se z a na časová okna (`TimeWindow`), která vyhodnocuje Strážce.
public struct ScheduleGrid: Equatable, Sendable {
    public static let slots = 48
    public static let slotMinutes = 30

    /// `cells[den][půlhodina]`, den 0 = pondělí.
    public var cells: [[Bool]]

    public init() {
        cells = Array(repeating: Array(repeating: false, count: Self.slots), count: 7)
    }

    /// Z oken; začátky a konce mimo půlhodiny se zaokrouhlí ven (políčko je plné, když do něj okno zasahuje).
    public init(windows: [TimeWindow]) {
        self.init()
        for w in windows {
            let first = w.start / Self.slotMinutes
            let last = (w.end + Self.slotMinutes - 1) / Self.slotMinutes
            for d in w.weekdays where (0..<7).contains(d) {
                if w.overnight {
                    fill(d, first..<Self.slots)
                    fill((d + 1) % 7, 0..<last)
                } else {
                    fill(d, first..<last)
                }
            }
        }
    }

    private mutating func fill(_ day: Int, _ range: Range<Int>) {
        for s in range where (0..<Self.slots).contains(s) { cells[day][s] = true }
    }

    public subscript(day: Int, slot: Int) -> Bool {
        get { cells[day][slot] }
        set { cells[day][slot] = newValue }
    }

    /// Nastaví obdélník dnů × půlhodin (tah myší z jednoho rohu do druhého).
    public mutating func set(days: ClosedRange<Int>, slots: ClosedRange<Int>, to value: Bool) {
        for d in days where (0..<7).contains(d) {
            for s in slots where (0..<Self.slots).contains(s) { cells[d][s] = value }
        }
    }

    public var isEmpty: Bool { !cells.contains { $0.contains(true) } }

    /// Souvislé úseky po dnech; stejné časy v různých dnech jsou jedno okno.
    public var windows: [TimeWindow] {
        var byTime: [(start: Int, end: Int, days: [Int])] = []
        for d in 0..<7 {
            var s = 0
            while s < Self.slots {
                guard cells[d][s] else { s += 1; continue }
                var e = s
                while e < Self.slots, cells[d][e] { e += 1 }
                let start = s * Self.slotMinutes, end = e * Self.slotMinutes
                if let i = byTime.firstIndex(where: { $0.start == start && $0.end == end }) { byTime[i].days.append(d) } else { byTime.append((start, end, [d])) }
                s = e
            }
        }
        return byTime.sorted { ($0.days[0], $0.start) < ($1.days[0], $1.start) }
            .map { TimeWindow(weekdays: $0.days, start: $0.start, end: $0.end) }
    }
}
