import AppModel
import Charts
import DesignSystem
import Engine
import Focus
import FocusStore
import SwiftUI

/// Statistiky Soustředění: čas u obrazovky po dnech, nejvíc času, pokusy po dnech a podle hodin,
/// odemknutí a porušení. Grafy jedné barvy (akcent), rozpad podle aplikací jako seznam s pruhy.
struct FocusStatsSection: View {
    @Environment(FocusController.self) private var focus
    @State private var days = 7
    @State private var stats: FocusStats?

    var body: some View {
        PageSection("Statistiky", accessory: {
            Picker("Období", selection: $days) {
                Text("7 dní").tag(7)
                Text("30 dní").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }) {
            if let stats {
                content(stats)
            } else {
                ProgressView().controlSize(.small).padding(.vertical, 12)
            }
        }
        .task(id: "\(days)-\((focus.report?.generatedAt ?? 0) / 60_000)") { await load() }
    }

    private func load() async {
        guard let store = focus.store else { return }
        let clock = StudyClock.current
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let first = clock.addDays(clock.startOfDay(now), -(days - 1))
        let usage = (try? await store.usage(fromDay: clock.dayKey(first), toDay: clock.dayKey(now))) ?? []
        let events = (try? await store.events(from: first, to: now + 1)) ?? []
        stats = FocusStats.make(usage: usage, events: events, days: days, now: now, clock: clock)
    }

    @ViewBuilder
    private func content(_ s: FocusStats) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 32) {
                figure("Čas u obrazovky", Format.duration(s.screenMs / 1000), note: "průměr \(Format.duration(s.screenMs / 1000 / max(1, s.days.count))) denně")
                figure("Pokusy", "\(s.attempts)", note: "průměr \(String(format: "%.1f", Double(s.attempts) / Double(max(1, s.days.count)))) denně")
                figure("Odemknutí", "\(s.unlocks)", note: s.tamper.isEmpty ? "bez porušení" : "porušení: \(s.tamper.count)")
            }
            ChartSection("Čas u obrazovky po dnech") { DayBars(days: s.days, value: { Double($0.screenMs) / 60_000 }, unit: .minutes) }
            ChartSection("Nejvíc času", meta: "aplikace a weby") { ShareBars(items: s.top.map { ($0.name, $0.isSite, $0.ms) }) }
            ChartSection("Pokusy po dnech") { DayBars(days: s.days, value: { Double($0.attempts) }, unit: .count) }
            ChartSection("Kdy tě to táhne", meta: "pokusy podle dne a hodiny") { AttemptHeatmap(grid: s.heatmap) }
            if !s.topAttempts.isEmpty {
                ChartSection("Nejčastější pokusy") {
                    ShareBars(items: s.topAttempts.map { ($0.name, $0.name.contains("."), $0.count) }, count: true)
                }
            }
            if !s.tamper.isEmpty {
                ChartSection("Porušení") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(s.tamper.prefix(8).enumerated()), id: \.offset) { _, e in
                            ListRow {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warn)
                                Text(e.detail).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Text(Self.dateText(e.at)).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                            }
                        }
                    }
                }
            }
        }
    }

    private func figure(_ label: String, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Typo.small).foregroundStyle(Palette.text3)
            Text(value).font(Typo.number(22)).foregroundStyle(Palette.text)
            Text(note).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
        }
        .accessibilityElement(children: .combine)
    }

    static func dateText(_ t: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = "d. M. H:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
    }
}

/// Sloupce po dnech v jedné barvě; najetím myší den a hodnota.
private struct DayBars: View {
    enum Unit { case minutes, count }

    let days: [FocusStats.Day]
    let value: (FocusStats.Day) -> Double
    let unit: Unit
    @State private var hover: String?

    var body: some View {
        let labels = days.map(label)
        let values = days.map(value)
        let top = values.max() ?? 0
        Chart {
            ForEach(days.indices, id: \.self) { i in
                BarMark(x: .value("Den", labels[i]), y: .value("Hodnota", values[i]))
                    .foregroundStyle(Palette.accent.opacity(hover == nil || hover == labels[i] ? 0.85 : 0.4))
                    .cornerRadius(2)
            }
            if let hover, let i = labels.firstIndex(of: hover) {
                RuleMark(x: .value("Den", hover))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        Text("\(hover): \(text(values[i]))")
                            .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
                    }
            }
        }
        .chartXScale(domain: labels)
        .chartXSelection(value: $hover)
        .chartYAxis {
            if unit == .minutes {
                minutesAxis(max: top)
            } else {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel()
                }
            }
        }
        .chartXAxis { AxisMarks { _ in AxisValueLabel(collisionResolution: .greedy) } }
        .chartChrome()
        .frame(height: 180)
    }

    private func label(_ d: FocusStats.Day) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = days.count <= 7 ? "EEEEEE d." : "d. M."
        return f.string(from: Date(timeIntervalSince1970: Double(d.start) / 1000))
    }

    private func text(_ v: Double) -> String {
        unit == .minutes ? Format.duration(Int(v * 60)) : "\(Int(v)) \(Int(v) == 1 ? "pokus" : Int(v) < 5 && Int(v) > 0 ? "pokusy" : "pokusů")"
    }
}

/// Podíl jako vodorovné pruhy (místo koláče): název, pruh, hodnota.
private struct ShareBars: View {
    let items: [(name: String, isSite: Bool, value: Int)]
    var count = false

    var body: some View {
        let top = max(1, items.map(\.value).max() ?? 1)
        if items.isEmpty {
            Text("Zatím nic naměřeno.").font(Typo.body).foregroundStyle(Palette.text3)
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    Image(systemName: item.isSite ? "globe" : "app").font(.system(size: 11)).foregroundStyle(Palette.text3).frame(width: 14)
                    Text(item.name).lineLimit(1).frame(width: 170, alignment: .leading)
                    ProgressLine(Double(item.value) / Double(top), color: Palette.accent)
                    Text(count ? "\(item.value)×" : Format.duration(item.value / 1000))
                        .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2).frame(width: 72, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Pokusy podle dne v týdnu a hodiny – jeden odstín, sytost podle počtu.
private struct AttemptHeatmap: View {
    let grid: [[Int]]
    @State private var hover: (day: Int, hour: Int)?
    private static let days = ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"]

    var body: some View {
        let top = max(1, grid.flatMap { $0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 3) {
                    Text(Self.days[d]).font(Typo.small).foregroundStyle(Palette.text3).frame(width: 22, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let n = grid[d][h]
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(n == 0 ? Palette.panel2 : Palette.accent.opacity(0.18 + 0.82 * Double(n) / Double(top)))
                            .frame(height: 16)
                            .onHover { inside in hover = inside ? (d, h) : nil }
                            .help("\(Self.days[d]) \(h):00–\(h + 1):00 · \(n)×")
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 22)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text("\(h)").font(.system(size: 10.5)).foregroundStyle(Palette.text3).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(hover.map { "\(Self.days[$0.day]) \($0.hour):00–\($0.hour + 1):00 · \(grid[$0.day][$0.hour]) pokusů" } ?? " ")
                .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2)
        }
        .accessibilityLabel("Pokusy podle dne a hodiny")
    }
}
