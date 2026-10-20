import AppModel
import Charts
import Core
import DesignSystem
import Engine
import SwiftUI

/// Statistiky (`StatsPage` na webu) ve vzhledu „Seznam“: souhrn jako řádky místo dlaždic, grafy ve Swift Charts,
/// barvu nesou předměty, ostatní je akcent a šedá.
public struct StatsView: View {
    @Environment(AppStore.self) private var store
    @State private var period = StatsPeriod.month
    @State private var subjectId: String?

    /// Pevná šířka a „teď“ bez posouvání – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private var snapshot: (width: CGFloat, now: Int)?

    public init() {}

    init(snapshotWidth: CGFloat, now: Int, period: StatsPeriod = .month) {
        snapshot = (snapshotWidth, now)
        _period = State(initialValue: period)
    }

    public var body: some View {
        let now = snapshot?.now ?? Int(Date().timeIntervalSince1970 * 1000)
        let state = StatsState(document: store.document, period: period, subjectId: subjectId, now: now, clock: store.clock)
        Group {
            if let snapshot {
                page(state, metrics: PageMetrics(width: snapshot.width))
            } else {
                GeometryReader { proxy in
                    ScrollView { page(state, metrics: PageMetrics(width: proxy.size.width)) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Statistiky")
    }

    private func page(_ state: StatsState, metrics: PageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 40) {
            PageHeader("Statistiky", subtitle: subtitle(state), glyph: .symbol("chart.bar")) {
                Picker("Předmět", selection: $subjectId) {
                    Text("Všechny předměty").tag(String?.none)
                    ForEach(subjects) { s in Text(s.name).tag(Optional(s.id)) }
                }
                .labelsHidden()
                .frame(width: 200)
                .accessibilityIdentifier("stats.subject")
                Picker("Období", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("stats.period")
            }
            if state.isEmpty {
                EmptyNote("Zatím tu nic není", systemImage: "chart.bar") {
                    Text("Jakmile odučíš první blok, objeví se tu grafy.")
                }
            } else {
                Facts(state: state, columns: metrics.size == .compact ? 1 : metrics.size == .regular ? 2 : 3)
                if !state.insights.isEmpty { Insights(tips: state.insights) }
                ColumnsLayout(columns: metrics.size == .compact ? 1 : 2, spacing: 56, rowSpacing: 44) {
                    ChartSection("Vývoj v čase", meta: state.days > 90 ? "posledních 90 dní" : "po dnech") { TrendChart(state: state) }
                    ChartSection("Rozložení", meta: Format.hours(state.totalSec)) { ShareList(rows: state.subjects) }
                    ChartSection("Předměty v čase", meta: state.byMonths ? "po měsících" : "po týdnech") { StackedChart(state: state) }
                    ChartSection("Kdy se učíš", meta: "den × hodina") { WeekHourChart(matrix: state.weekHour) }
                    ChartSection("Hodiny dne a soustředění", meta: "minuty · průměrné soustředění") { HoursChart(hours: state.hours) }
                    ChartSection("Celý rok", meta: "posledních 365 dní") { YearHeatmap(days: state.year, clock: store.clock) }
                }
                ChartSection("Podle předmětů") { SubjectTable(rows: state.subjects) }
            }
        }
        .padding(.leading, metrics.size == .compact ? metrics.padding : 64)
        .padding(.trailing, metrics.size == .compact ? metrics.padding : 48)
        .padding(.vertical, 48)
        .frame(maxWidth: metrics.size == .regular ? 1280 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subjects: [Subject] {
        store.document.alive(Subject.self).filter { !$0.archived }
    }

    /// „42,5 h za posledních 30 dní · o 12 % víc než předtím“
    private func subtitle(_ s: StatsState) -> String {
        guard !s.isEmpty else { return "Grafy a souhrny učení" }
        var parts = ["\(Format.hours(s.totalSec)) \(s.period.phrase)"]
        if let change = s.change {
            parts.append(change == 0 ? "stejně jako předtím" : "o \(abs(change)) % \(change > 0 ? "víc" : "míň") než předtím")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Souhrn a postřehy

/// Souhrn období Statistik.
private struct Facts: View {
    let state: StatsState
    let columns: Int

    var body: some View {
        FactRows(title: "Souhrn", facts: facts, columns: columns).accessibilityIdentifier("stats.facts")
    }

    private var facts: [Fact] {
        let s = state
        var total = Fact(label: "Celkem", value: Format.hours(s.totalSec), note: "bez srovnání")
        if let c = s.change { total = Fact.change(label: "Celkem", value: Format.hours(s.totalSec), change: c, suffix: " proti předchozímu") }
        let anki = s.ankiBlocks > 0 ? " + \(s.ankiBlocks)× Anki" : ""
        return [
            total,
            Fact(label: "Ø na den", value: Format.duration(s.perDaySec), note: "za celé období"),
            Fact(label: "Aktivní dny", value: "\(s.activeDays) z \(s.days)",
                 note: "\(Int(JS.round(Double(s.activeDays) / Double(s.days) * 100))) % pravidelnost"),
            Fact(label: "Ø blok", value: Format.duration(s.avgBlockSec), note: "\(s.blocks) \(Format.plural(s.blocks, "blok", "bloky", "bloků"))\(anki)"),
            Fact(label: "Soustředění", value: s.focus.map { "\(Format.decimal($0)) z 5" } ?? "–", note: "průměr hodnocení"),
            Fact(label: "Nejsilnější okno", value: s.peak.map { "\($0.from)–\($0.to) h" } ?? "–", note: "kdy se učíš nejvíc"),
        ]
    }
}

private struct Insights: View {
    let tips: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListHeading("Postřehy")
            ForEach(tips, id: \.self) { t in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lightbulb").font(.system(size: 12)).foregroundStyle(Palette.accent)
                    Text(t).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13.5))
                .padding(.vertical, 8)
            }
        }
        .accessibilityIdentifier("stats.insights")
    }
}

private struct TrendChart: View {
    let state: StatsState

    var body: some View {
        Chart {
            ForEach(state.trend) { d in
                BarMark(x: .value("Den", Date(timeIntervalSince1970: Double(d.day) / 1000), unit: .day), y: .value("Minuty", d.minutes))
                    .foregroundStyle(Palette.accent.opacity(0.85))
                    .cornerRadius(2)
            }
            if state.goalMinutes > 0 {
                RuleMark(y: .value("Cíl", state.goalMinutes))
                    .foregroundStyle(Palette.text3)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("cíl \(Format.duration(state.goalMinutes * 60))").font(.system(size: 10.5)).foregroundStyle(Palette.text3)
                    }
            }
        }
        .chartYAxis { minutesAxis(max: max(Double(state.goalMinutes), state.trend.map(\.minutes).max() ?? 0)) }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: .dateTime.day().month(.defaultDigits)) } }
        .chartChrome()
        .frame(height: 240)
        .accessibilityLabel("Vývoj učení po dnech")
    }
}

/// Podíl předmětů jako vodorovné pruhy (místo koláče).
private struct ShareList: View {
    let rows: [StatsState.SubjectRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(rows.prefix(8)) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.subject(r.subject.color)).frame(width: 7, height: 7)
                        Text(r.subject.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Format.duration(r.sec)).monospacedDigit().foregroundStyle(Palette.text2)
                        Text("\(r.percent) %").monospacedDigit().foregroundStyle(Palette.text3).frame(width: 40, alignment: .trailing)
                    }
                    GeometryReader { g in
                        Capsule().fill(Palette.subject(r.subject.color)).frame(width: max(3, g.size.width * Double(r.percent) / 100), height: 4)
                    }
                    .frame(height: 4)
                }
                .font(.system(size: 13))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct StackedChart: View {
    let state: StatsState

    var body: some View {
        let subjects = orderedSubjects
        Chart(state.stacked) { v in
            BarMark(x: .value("Období", v.label), y: .value("Minuty", v.minutes))
                .foregroundStyle(by: .value("Předmět", v.subject.id))
        }
        .chartForegroundStyleScale(domain: subjects.map(\.id), range: subjects.map { Palette.subject($0.color) })
        .chartLegend(.hidden)
        .chartYAxis { minutesAxis(max: bucketMax) }
        .chartXAxis { AxisMarks { _ in AxisValueLabel(collisionResolution: .greedy) } }
        .chartChrome()
        .frame(height: 240)
        .accessibilityLabel("Předměty v čase")
    }

    private var bucketMax: Double {
        Dictionary(grouping: state.stacked, by: \.bucket).values.map { $0.reduce(0) { $0 + $1.minutes } }.max() ?? 0
    }

    private var orderedSubjects: [SubjectInfo] {
        var seen = Set<String>()
        return state.stacked.map(\.subject).filter { seen.insert($0.id).inserted }
    }
}

private struct WeekHourChart: View {
    let matrix: [[Double]]

    var body: some View {
        let top = matrix.flatMap { $0 }.max() ?? 0
        Chart {
            ForEach(0..<7, id: \.self) { d in
                ForEach(0..<24, id: \.self) { h in
                    let v = matrix[d][h]
                    RectangleMark(xStart: .value("Od", Double(h) + 0.06), xEnd: .value("Do", Double(h) + 0.94),
                                  yStart: .value("Den", Double(d) + 0.08), yEnd: .value("Den", Double(d) + 0.92))
                        .foregroundStyle(v > 0 && top > 0 ? Palette.accent.opacity(0.15 + 0.85 * v / top) : Palette.panel2)
                        .cornerRadius(2)
                }
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: [7, 0])
        .chartXAxis { AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21].map { Double($0) + 0.5 }) { v in AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))") } } }
        .chartYAxis {
            AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { v in
                AxisValueLabel { Text(Format.weekdaysShort[Int(v.as(Double.self) ?? 0)]) }
            }
        }
        .chartChrome()
        .frame(height: 220)
        .accessibilityLabel("Kdy se učíš: den v týdnu a hodina")
    }
}

private struct HoursChart: View {
    let hours: [StatsState.HourValue]

    var body: some View {
        let top = max(1, hours.map(\.minutes).max() ?? 1)
        // Soustředění 1–5 na stejné ploše: 5 = nejvyšší sloupec.
        let scale = { (f: Double) in f / 5 * top }
        Chart {
            ForEach(hours) { h in
                BarMark(x: .value("Hodina", h.hour), y: .value("Minuty", h.minutes), width: .fixed(9))
                    .foregroundStyle(Palette.accent.opacity(0.85))
                    .cornerRadius(2)
            }
            ForEach(hours.filter { $0.focus != nil }) { h in
                LineMark(x: .value("Hodina", h.hour), y: .value("Soustředění", scale(h.focus!)))
                    .foregroundStyle(Palette.focus)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Hodina", h.hour), y: .value("Soustředění", scale(h.focus!)))
                    .foregroundStyle(Palette.focus)
                    .symbolSize(18)
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis { AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0)") } } }
        .chartYAxis {
            minutesAxis(max: top)
            AxisMarks(position: .trailing, values: [1, 3, 5].map(scale)) { v in
                AxisValueLabel { Text("\(Int(((v.as(Double.self) ?? 0) / top * 5).rounded()))").foregroundStyle(Palette.focus) }
            }
        }
        .chartChrome()
        .frame(height: 220)
        .accessibilityLabel("Minuty učení a soustředění podle hodiny dne")
    }
}

/// Posledních 365 dní po týdnech (sloupce) a dnech (řádky, pondělí nahoře), sytost podle minut.
private struct YearHeatmap: View {
    let days: [StatsState.DayValue]
    let clock: StudyClock

    var body: some View {
        let max = Swift.max(60, days.map(\.minutes).max() ?? 0)
        let firstWeekday = days.first.map { clock.weekdayIndex($0.day) } ?? 0
        let weeks = (firstWeekday + days.count + 6) / 7
        let months = monthStarts(firstWeekday: firstWeekday)
        Canvas { ctx, size in
            let labelHeight: CGFloat = 16
            let cell = min((size.width - 2) / CGFloat(weeks), (size.height - labelHeight) / 7)
            for (i, d) in days.enumerated() {
                let k = firstWeekday + i
                let rect = CGRect(x: CGFloat(k / 7) * cell, y: labelHeight + CGFloat(k % 7) * cell, width: cell - 2.5, height: cell - 2.5)
                let color = d.minutes > 0 ? Palette.accent.opacity(0.18 + 0.82 * Swift.min(1, d.minutes / max)) : Palette.panel2
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
            for m in months {
                ctx.draw(Text(m.label).font(.system(size: 10.5)).foregroundStyle(Palette.text3),
                         at: CGPoint(x: CGFloat(m.week) * cell, y: 6), anchor: .leading)
            }
        }
        .frame(height: 16 + 7 * 15)
        .accessibilityElement()
        .accessibilityLabel("Celý rok: \(days.filter { $0.minutes > 0 }.count) dní s učením")
    }

    /// Týden, ve kterém začíná měsíc, a jeho zkratka.
    private func monthStarts(firstWeekday: Int) -> [(week: Int, label: String)] {
        let names = ["led", "úno", "bře", "dub", "kvě", "čvn", "čvc", "srp", "zář", "říj", "lis", "pro"]
        var out: [(Int, String)] = []
        for (i, d) in days.enumerated() where clock.calendar.component(.day, from: clock.date(d.day)) == 1 {
            let week = (firstWeekday + i) / 7
            if week > 0 || i == 0 { out.append((week, names[clock.calendar.component(.month, from: clock.date(d.day)) - 1])) }
        }
        return out
    }
}

private struct SubjectTable: View {
    let rows: [StatsState.SubjectRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
            GridRow {
                Text("Předmět")
                Text("Čas").gridColumnAlignment(.trailing)
                Text("Podíl").gridColumnAlignment(.trailing)
                Text("Sezení").gridColumnAlignment(.trailing)
                Text("Ø blok").gridColumnAlignment(.trailing)
                Text("Soustředění").gridColumnAlignment(.trailing)
            }
            .font(Typo.small).foregroundStyle(Palette.text3)
            .padding(.bottom, 6)
            ForEach(rows) { r in
                Divider().overlay(Palette.line).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    HStack(spacing: 7) {
                        Circle().fill(Palette.subject(r.subject.color)).frame(width: 7, height: 7)
                        Text(r.subject.name).lineLimit(1)
                    }
                    Text(Format.duration(r.sec))
                    Text("\(r.percent) %")
                    Text("\(r.sessions)")
                    Text(Format.duration(r.avgSec))
                    Text(r.focus.map { Format.decimal($0) } ?? "–")
                }
                .monospacedDigit()
                .padding(.vertical, 8)
            }
        }
        .font(.system(size: 13.5))
        .accessibilityIdentifier("stats.table")
    }
}
