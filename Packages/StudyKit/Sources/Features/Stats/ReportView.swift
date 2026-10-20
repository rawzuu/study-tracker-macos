import AppKit
import AppModel
import Charts
import Core
import DesignSystem
import Engine
import SwiftUI

/// Data měsíčního reportu (`ReportPage` na webu): tento a minulý měsíc, postřehy, části dne, předměty.
struct ReportState {
    let year: Int
    let month: Int
    let cur: PeriodStats
    let prev: PeriodStats
    let highlights: [String]
    let inProgress: Bool
    let canGoForward: Bool
    /// Návrhy úprav patří k poslednímu uzavřenému měsíci.
    let isLastClosed: Bool
    let topics: Int
    let daily: [Double]
    let focusByHour: [Double?]
    let subjects: [(subject: SubjectInfo, cur: Int, prev: Int)]

    init(document doc: AppDocument, year: Int, month: Int, now: Int, clock: StudyClock) {
        self.year = year
        self.month = month
        let settings = doc.settings
        let all = doc.alive(Session.self), blocks = doc.records(PlanBlock.self)
        let range = Report.monthRange(year: year, month: month, clock: clock)
        let before = Report.shift(year: year, month: month, by: -1)
        let prevRange = Report.monthRange(year: before.year, month: before.month, clock: clock)
        cur = PeriodStats(sessions: all, blocks: blocks, from: range.from, to: range.to, restDays: settings.streakRestDays,
                          minMin: settings.streakMinMin, now: now, clock: clock)
        prev = PeriodStats(sessions: all, blocks: blocks, from: prevRange.from, to: prevRange.to, restDays: settings.streakRestDays,
                           minMin: settings.streakMinMin, now: now, clock: clock)
        highlights = Report.highlights(cur, prev, subjects: doc.records(Subject.self), clock: clock)
        inProgress = now >= range.from && now < range.to
        canGoForward = !(range.from > now || inProgress)
        isLastClosed = range.to == clock.startOfMonth(now)
        let inMonth = Stats.inRange(all, from: range.from, to: range.to)
        topics = Set(inMonth.filter { !$0.topic.isEmpty }.map { "\($0.subjectId)|\($0.topic.lowercased())" }).count
        let daysIn = clock.calendar.range(of: .day, in: .month, for: clock.date(range.from))?.count ?? 30
        let cur = cur
        daily = (0..<daysIn).map { Double(cur.secOf(day: clock.dayKey(clock.addDays(range.from, $0)))) / 60 }
        focusByHour = StatsState.focusByHour(inMonth, clock: clock)
        let lookup = SubjectLookup(doc)
        var ids = cur.perSubject.map(\.id)
        for p in prev.perSubject where !ids.contains(p.id) { ids.append(p.id) }
        let prev = prev
        var rows: [(subject: SubjectInfo, cur: Int, prev: Int)] = []
        for id in ids { rows.append((lookup[id], cur.secOf(subject: id), prev.secOf(subject: id))) }
        subjects = rows.stableSorted { $0.cur > $1.cur }
    }

    var title: String { "\(Format.capitalized(Report.months[month])) \(year)" }
}

/// Měsíční report ve vzhledu „Seznam“: souhrn jako řádky, postřehy, návrhy na další měsíc, grafy a tisk do PDF.
public struct ReportView: View {
    @Environment(AppStore.self) private var store
    @State private var month: (year: Int, month: Int)?

    private var snapshot: (width: CGFloat, now: Int)?
    /// Tisk: bez ovládacích prvků a návrhů, pevná šířka.
    private var printing = false

    public init() {}

    init(snapshotWidth: CGFloat, now: Int, month: (year: Int, month: Int)? = nil, printing: Bool = false) {
        snapshot = (snapshotWidth, now)
        _month = State(initialValue: month)
        self.printing = printing
    }

    public var body: some View {
        let now = snapshot?.now ?? Int(Date().timeIntervalSince1970 * 1000)
        let ym = month ?? Report.defaultMonth(now: now, clock: store.clock)
        let state = ReportState(document: store.document, year: ym.year, month: ym.month, now: now, clock: store.clock)
        Group {
            if let snapshot {
                page(state, metrics: PageMetrics(width: snapshot.width), now: now)
            } else {
                GeometryReader { proxy in
                    ScrollView { page(state, metrics: PageMetrics(width: proxy.size.width), now: now) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Měsíční report")
    }

    private func page(_ state: ReportState, metrics: PageMetrics, now: Int) -> some View {
        let wide = metrics.size != .compact
        return VStack(alignment: .leading, spacing: 40) {
            PageHeader(state.title, subtitle: "Měsíční report\(state.inProgress ? " · průběžný" : "")", glyph: .symbol("doc.text")) {
                if !printing {
                    Button { shift(state, -1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.study(.normal, size: .small)).help("Předchozí měsíc").accessibilityIdentifier("report.prev")
                    Button { shift(state, 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.study(.normal, size: .small)).help("Další měsíc").disabled(!state.canGoForward).accessibilityIdentifier("report.next")
                    Button { print(state, now: now) } label: { Label("Tisk / PDF", systemImage: "printer") }
                        .buttonStyle(.study(.normal, size: .small)).accessibilityIdentifier("report.print")
                }
            }
            if state.cur.sessions == 0 {
                EmptyNote("V \(Report.monthsIn[state.month]) žádné učení", systemImage: "doc.text") { Text("Vyber jiný měsíc šipkami.") }
            } else {
                FactRows(title: "Souhrn", facts: facts(state), columns: metrics.factColumns)
                    .accessibilityIdentifier("report.facts")
                if state.isLastClosed && !printing {
                    CalibrationSection(year: state.year, month: state.month, now: now)
                }
                ColumnsLayout(columns: wide ? 2 : 1, spacing: 56, rowSpacing: 44) {
                    ChartSection("Postřehy") { Highlights(items: state.highlights) }
                    ChartSection("Den po dni", meta: "minuty učení · nejlepší den zvýrazněn") {
                        HighlightBars(labels: state.daily.indices.map { "\($0 + 1)" }, minutes: state.daily)
                    }
                    ChartSection("Dny v týdnu", meta: "průměr") { HighlightBars(labels: Format.weekdaysShort, minutes: state.cur.weekdayAvg, height: 200) }
                    ChartSection("Hodiny dne", meta: state.cur.peakWindow.map { "špička \($0.from)–\($0.to) h" }) {
                        ReportHours(minutes: state.cur.hourMinutes, focus: state.focusByHour)
                    }
                    ChartSection("Část dne", meta: state.cur.chronotype) { DayParts(state: state) }
                    ChartSection("Předměty vs. minulý měsíc") { SubjectCompare(state: state) }
                }
                FactRows(title: "Další", facts: more(state), columns: metrics.factColumns)
            }
        }
        .padding(.leading, metrics.size == .compact ? metrics.padding : 64)
        .padding(.trailing, metrics.size == .compact ? metrics.padding : 48)
        .padding(.vertical, 48)
        .frame(maxWidth: metrics.size == .regular ? 1280 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func facts(_ s: ReportState) -> [Fact] {
        let c = s.cur, p = s.prev
        return [
            Fact.change(label: "Celkem", value: Format.hours(c.total), change: Report.pct(Double(c.total), Double(p.total))),
            Fact(label: "Aktivní dny", value: "\(c.activeDays) z \(c.days)", note: "\(Int(JS.round(c.consistency * 100))) % pravidelnost"),
            Fact.change(label: "Ø na aktivní den", value: Format.duration(c.avgPerActiveDay), change: Report.pct(c.avgPerActiveDay, p.avgPerActiveDay)),
            Fact(label: "Ø blok", value: Format.duration(c.avgSession), note: "\(c.sessions) sezení"),
            Fact(label: "Soustředění", value: c.focus.map { "\(Format.decimal($0)) z 5" } ?? "–",
                 note: p.focus != nil && c.focus != nil ? "minule \(Format.decimal(p.focus!))" : "průměr hodnocení"),
            Fact(label: "Nejdelší série", value: "\(c.longestStreak) \(Format.plural(c.longestStreak, "den", "dny", "dní"))", note: "v řadě"),
        ]
    }

    private func more(_ s: ReportState) -> [Fact] {
        let c = s.cur, p = s.prev
        return [
            Fact(label: "Hluboká práce", value: "\(Int(JS.round(c.deepShare * 100))) %", note: "času v blocích 45+ min"),
            Fact(label: "Vyrušení za hodinu", value: Format.decimal(c.interruptionsPerHour), note: p.sessions > 0 ? "minule \(Format.decimal(p.interruptionsPerHour))" : nil),
            Fact(label: "Plnění plánu", value: c.planAdherence.map { "\(Int(JS.round($0 * 100))) %" } ?? "–",
                 note: c.plannedSec > 0 ? "naplánováno \(Format.duration(c.plannedSec))" : "bez plánu"),
            Fact(label: "Témata", value: "\(s.topics)", note: "různých témat"),
            Fact(label: "Nejsilnější den", value: c.bestDay.map { Format.duration($0.sec) } ?? "–",
                 note: c.bestDay.flatMap { store.clock.parseDayKey($0.key) }.map { Format.date($0, .shortWeekdayDayNumericMonth, clock: store.clock) }),
        ]
    }

    private func shift(_ s: ReportState, _ delta: Int) {
        month = Report.shift(year: s.year, month: s.month, by: delta)
    }

    /// Systémový tisk (i do PDF): report bez ovládacích prvků ve světlém vzhledu.
    private func print(_ s: ReportState, now: Int) {
        let width: CGFloat = 1000
        let content = ReportView(snapshotWidth: width, now: now, month: (s.year, s.month), printing: true)
            .environment(store)
            .environment(\.colorScheme, .light)
            .frame(width: width)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.jobDisposition = .spool
        let op = NSPrintOperation(view: host, printInfo: info)
        op.jobTitle = "Měsíční report – \(s.title)"
        op.run()
    }
}

private struct Highlights: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(Palette.accent).frame(width: 18, alignment: .trailing)
                    Text(t).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13.5))
            }
        }
        .accessibilityIdentifier("report.highlights")
    }
}

private struct ReportHours: View {
    let minutes: [Double]
    let focus: [Double?]

    var body: some View {
        let top = Swift.max(1, minutes.max() ?? 1)
        let scale = { (f: Double) in f / 5 * top }
        Chart {
            ForEach(0..<24, id: \.self) { h in
                BarMark(x: .value("Hodina", h), y: .value("Minuty", minutes[h]), width: .fixed(7))
                    .foregroundStyle(Palette.accent.opacity(0.85))
                    .cornerRadius(2)
            }
            ForEach((0..<24).filter { focus[$0] != nil }, id: \.self) { h in
                LineMark(x: .value("Hodina", h), y: .value("Soustředění", scale(focus[h]!)))
                    .foregroundStyle(Palette.focus)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0)") } } }
        .chartYAxis { minutesAxis(max: top) }
        .chartChrome()
        .frame(height: 200)
    }
}

private struct DayParts: View {
    let state: ReportState

    var body: some View {
        let totalMin = Swift.max(1, Double(state.cur.total) / 60)
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
            GridRow {
                Text("")
                Text("Čas").gridColumnAlignment(.trailing)
                Text("Podíl").gridColumnAlignment(.trailing)
                Text("Soustředění").gridColumnAlignment(.trailing)
            }
            .font(Typo.small).foregroundStyle(Palette.text3).padding(.bottom, 6)
            ForEach(state.cur.dayparts, id: \.label) { p in
                Divider().overlay(Palette.line).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(p.label)
                    Text(Format.duration(p.min * 60))
                    Text("\(Int(JS.round(p.min / totalMin * 100))) %")
                    Text(p.focus.map { Format.decimal($0) } ?? "–")
                }
                .monospacedDigit()
                .padding(.vertical, 8)
            }
        }
        .font(.system(size: 13.5))
    }
}

/// Předměty tento a minulý měsíc: dva pruhy pod sebou (minulý tlumeně) a rozdíl.
private struct SubjectCompare: View {
    let state: ReportState

    var body: some View {
        let top = Double(Swift.max(1, state.subjects.map { Swift.max($0.cur, $0.prev) }.max() ?? 1))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(state.subjects, id: \.subject.id) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.subject(r.subject.color)).frame(width: 7, height: 7)
                        Text(r.subject.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Format.duration(r.cur)).monospacedDigit()
                        Group {
                            if r.prev == 0 {
                                Text("nové").foregroundStyle(Palette.text3)
                            } else {
                                Text("\(r.cur >= r.prev ? "+" : "−")\(Format.duration(abs(r.cur - r.prev)))")
                                    .foregroundStyle(r.cur >= r.prev ? Palette.success : Palette.danger)
                            }
                        }
                        .font(Typo.small).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    GeometryReader { g in
                        VStack(alignment: .leading, spacing: 2) {
                            Capsule().fill(Palette.subject(r.subject.color)).frame(width: Swift.max(2, g.size.width * Double(r.cur) / top), height: 4)
                            Capsule().fill(Palette.subject(r.subject.color).opacity(0.3)).frame(width: Swift.max(2, g.size.width * Double(r.prev) / top), height: 3)
                        }
                    }
                    .frame(height: 9)
                }
                .font(.system(size: 13))
                .accessibilityElement(children: .combine)
            }
            Text("Silný pruh tento měsíc, slabý minulý.").font(Typo.small).foregroundStyle(Palette.text3)
        }
    }
}

// MARK: - Návrhy na další měsíc

/// Kalibrace v reportu za uzavřený měsíc (`CalibrationCard` na webu): Použít / Ponechat / Vrátit.
struct CalibrationSection: View {
    @Environment(AppStore.self) private var store
    let year: Int
    let month: Int
    let now: Int

    private static let titles: [Calibrate.Key: String] = [.dailyGoal: "Denní cíl", .weeklyGoals: "Týdenní cíle předmětů", .dayWindow: "Časové okno ranního plánu"]

    /// Řádek návrhu: už rozhodnutý (záznam v historii) nebo čekající návrh.
    struct Row: Identifiable {
        let key: Calibrate.Key
        let entryIndex: Int?
        let entry: CalibrationEntry?
        let suggestion: Calibrate.Suggestion?
        var id: String { key.rawValue }
    }

    static func rows(log: [CalibrationEntry], month: String, suggestions: [Calibrate.Suggestion]) -> [Row] {
        var out: [Row] = []
        for k in Calibrate.Key.allCases {
            var index: Int?
            for (i, e) in log.enumerated() where e.month == month && e.key == k.rawValue {
                index = i
                break
            }
            let suggestion = suggestions.first { $0.key == k }
            if index != nil || suggestion != nil {
                out.append(Row(key: k, entryIndex: index, entry: index.map { log[$0] }, suggestion: suggestion))
            }
        }
        return out
    }

    var body: some View {
        let clock = store.clock
        let doc = store.document
        let key = Calibrate.monthKey(year: year, month: month)
        let end = min(Report.monthRange(year: year, month: month, clock: clock).to, now)
        let rows = Self.rows(log: doc.settings.calibration, month: key, suggestions: Calibrate.suggestions(doc, end: end, clock: clock))
        let enough = Calibrate.enoughData(doc, end: end, clock: clock)
        return VStack(alignment: .leading, spacing: 0) {
            ListHeading("Návrhy na další měsíc", meta: "podle posledních 8 týdnů")
            if rows.isEmpty {
                Text(enough ? "Cíle i plán odpovídají tomu, jak se opravdu učíš. Není co měnit."
                     : "Na návrhy je zatím málo dat. Objeví se tady, až bude za posledních 8 týdnů aspoň 10 studijních dní.")
                    .font(.system(size: 13.5)).foregroundStyle(Palette.text2).padding(.vertical, 8)
            }
            ForEach(rows) { row in rowView(row, month: key) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("report.calibration")
    }

    private func rowView(_ row: Row, month: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.titles[row.key] ?? "").fontWeight(.semibold)
                rowValues(row)
            }
            .font(.system(size: 13.5))
            Spacer(minLength: 16)
            rowActions(row, month: month)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    @ViewBuilder
    private func rowValues(_ row: Row) -> some View {
        if let entry = row.entry {
            if entry.action == "applied" {
                let before = describe(row.key, entry.raw["before"]), after = describe(row.key, entry.raw["after"])
                HStack(spacing: 6) {
                    Text(before).foregroundStyle(Palette.text3)
                    Text("→")
                    Text(after).fontWeight(.semibold)
                    Text("· použito").foregroundStyle(Palette.success)
                }
                .monospacedDigit()
            } else {
                Text("ponecháno beze změny").foregroundStyle(Palette.text3)
            }
        } else if let s = row.suggestion {
            HStack(spacing: 6) {
                Text(s.current).foregroundStyle(Palette.text3)
                Text("→")
                Text(s.proposed).fontWeight(.semibold)
            }
            .monospacedDigit()
            ForEach(s.reasons, id: \.self) { r in
                Text("· \(r)").font(Typo.small).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ row: Row, month: String) -> some View {
        if let entry = row.entry, let index = row.entryIndex {
            Button("Vrátit") { undo(index, entry) }.buttonStyle(.study(.ghost, size: .small))
        } else if let s = row.suggestion {
            Button("Použít") { apply(s, month: month) }.buttonStyle(.study(.primary, size: .small)).accessibilityIdentifier("calibration.apply.\(s.key.rawValue)")
            Button("Ponechat") { keep(s, month: month) }.buttonStyle(.study(.ghost, size: .small))
        }
    }

    /// Hodnota z historie návrhů v čitelné podobě (`describe`).
    private func describe(_ key: Calibrate.Key, _ v: JSONValue?) -> String {
        switch key {
        case .dailyGoal: return v?.numberValue.map { Format.duration($0 * 60) } ?? ""
        case .weeklyGoals:
            guard let o = v?.objectValue else { return "" }
            return "\(Format.duration(o.compactMap { $0.value.numberValue }.reduce(0, +) * 60)) týdně"
        case .dayWindow:
            guard let o = v?.objectValue, let s = o.string("start"), let e = o.string("end") else { return "" }
            let strip = { (t: String) in t.hasPrefix("0") ? String(t.dropFirst()) : t }
            return "\(strip(s))–\(strip(e))"
        }
    }

    private func apply(_ s: Calibrate.Suggestion, month: String) {
        let now = store.nowMs
        if !s.subjects.isEmpty {
            let updated: [Subject] = s.subjects.compactMap { n in
                guard var subject = store.document.record(Subject.self, id: n.id) else { return nil }
                subject.weeklyGoalMin = n.weeklyGoalMin
                return subject
            }
            store.upsert(updated)
        }
        let entry = CalibrationEntry(raw: ["month": .string(month), "key": .string(s.key.rawValue), "action": "applied",
                                           "at": .number(Double(now)), "before": s.before, "after": s.after])
        store.updateSettings { settings in
            for (k, v) in s.settings { settings.raw[k] = v }
            settings.calibration = settings.calibration + [entry]
        }
    }

    private func keep(_ s: Calibrate.Suggestion, month: String) {
        let entry = CalibrationEntry(raw: ["month": .string(month), "key": .string(s.key.rawValue), "action": "kept", "at": .number(Double(store.nowMs))])
        store.updateSettings { $0.calibration = $0.calibration + [entry] }
    }

    private func undo(_ index: Int, _ e: CalibrationEntry) {
        if e.action == "applied", e.key == Calibrate.Key.weeklyGoals.rawValue, let before = e.raw["before"]?.objectValue {
            let restored: [Subject] = store.document.records(Subject.self).filter { !$0.isDeleted }.compactMap { s in
                guard let v = before.int(s.id) else { return nil }
                var s = s
                s.weeklyGoalMin = v
                return s
            }
            store.upsert(restored)
        }
        store.updateSettings { settings in
            var log = settings.calibration
            if log.indices.contains(index) { log.remove(at: index) }
            settings.calibration = log
            guard e.action == "applied" else { return }
            if e.key == Calibrate.Key.dailyGoal.rawValue, let before = e.raw["before"]?.numberValue { settings.dailyGoalMin = Int(before) }
            if e.key == Calibrate.Key.dayWindow.rawValue, let before = e.raw["before"]?.objectValue {
                if let s = before.string("start") { settings.planDayStart = s }
                if let end = before.string("end") { settings.planDayEnd = end }
            }
        }
    }
}
