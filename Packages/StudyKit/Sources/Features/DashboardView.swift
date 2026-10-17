import AppModel
import DesignSystem
import Engine
import SwiftUI

/// Přehled – zatím jen pro čtení (M1): dnešek, týden po předmětech, plán, opakování, zkoušky, poslední sezení.
public struct DashboardView: View {
    @Environment(AppStore.self) private var store
    let openPage: (String) -> Void

    public init(openPage: @escaping (String) -> Void = { _ in }) {
        self.openPage = openPage
    }

    public var body: some View {
        // Každou minutu se přepočítá „teď“ (dnešek, série, „dnes“ v seznamu).
        TimelineView(.everyMinute) { context in
            let now = Int(context.date.timeIntervalSince1970 * 1000)
            let state = DashboardState(document: store.document, now: now, clock: store.clock)
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    PageHeader(state.title, subtitle: "Týden \(state.isoWeek)")
                    SyncBanner(openSettings: { openPage("nastaveni") })
                    if state.isEmpty && !store.isConnected {
                        ConnectPrompt(openSettings: { openPage("nastaveni") })
                    } else {
                        content(state)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 36)
                .frame(maxWidth: 2200, alignment: .leading)
            }
        }
        .pageBackground()
        .navigationTitle("Přehled")
    }

    @ViewBuilder
    private func content(_ s: DashboardState) -> some View {
        FlowRow {
            TodaySection(state: s).frame(minWidth: 460, maxWidth: .infinity)
            WeekSection(state: s).frame(minWidth: 440, maxWidth: .infinity)
        }
        FlowRow {
            PlanSection(rows: s.todayPlan).frame(minWidth: 320, maxWidth: .infinity)
            DueSection(rows: s.dueTopics).frame(minWidth: 320, maxWidth: .infinity)
            ExamsSection(rows: s.exams).frame(minWidth: 320, maxWidth: .infinity)
        }
        RecentSection(rows: s.recent, openHistory: { openPage("historie") })
    }
}

/// Sekce vedle sebe; když se nevejdou, pod sebou (`.dash-row` na webu).
struct FlowRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 56) { content }
            VStack(alignment: .leading, spacing: 40) { content }
        }
    }
}

// MARK: - Dnešek

private struct TodaySection: View {
    let state: DashboardState

    var body: some View {
        PageSection("Dnešek") {
            HStack(alignment: .center, spacing: 30) {
                DayGauge(rings: [
                    .init(label: "Dnes", value: state.goalSec > 0 ? Double(state.todaySec) / Double(state.goalSec) : 0, color: Palette.accent),
                    .init(label: "Týden", value: state.weekGoalSec > 0 ? Double(state.weekSec) / Double(state.weekGoalSec) : 0, color: Palette.breakColor),
                    .init(label: "Soustředění", value: (state.focus7 ?? 0) / 5, color: Palette.focus),
                ], valueText: Format.duration(state.todaySec), sub: state.goalSec > 0 ? "ze \(Format.duration(state.goalSec))" : "dnes")
                VStack(alignment: .leading, spacing: 0) {
                    LegendRow(color: Palette.accent, label: "Dnes", value: Format.duration(state.todaySec),
                              of: state.goalSec > 0 ? (state.todaySec >= state.goalSec ? "cíl splněn" : "ze \(Format.duration(state.goalSec))") : "bez cíle")
                    LegendRow(color: Palette.breakColor, label: "Týden", value: Format.duration(state.weekSec),
                              of: state.weekGoalSec > 0 ? "z \(Format.duration(state.weekGoalSec))" : "bez cíle")
                    LegendRow(color: Palette.focus, label: "Soustředění", value: state.focus7.map { Format.decimal($0) } ?? "—",
                              of: state.focus7 != nil ? "z 5 · 7 dní" : "bez hodnocení")
                    footer.padding(.top, 12)
                }
                .frame(minWidth: 200)
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier("dash.today")
    }

    private var footer: some View {
        let current = state.streak.current
        return WrapLayout(spacing: 20, lineSpacing: 4) {
            HStack(spacing: 4) {
                Text("Série")
                Text("\(current)").foregroundStyle(Palette.text).monospacedDigit()
                Text(Format.plural(current, "den", "dny", "dní"))
                if state.streak.best > current {
                    Text("· rekord \(state.streak.best)").foregroundStyle(Palette.text3)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dash.streak")
            HStack(spacing: 4) {
                Text("K zopakování")
                Text("\(state.dueTopics.count)").foregroundStyle(Palette.text).monospacedDigit()
            }
            if let delta = state.weekDelta {
                Text("\(delta >= 0 ? "+" : "−")\(Int((abs(delta) * 100).rounded())) % proti minulému týdnu")
                    .foregroundStyle(delta >= 0 ? Palette.success : Palette.warn)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.text2)
    }
}

private struct LegendRow: View {
    let color: Color
    let label: String
    let value: String
    let of: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Rectangle().fill(color).frame(width: 14, height: 3).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            Text(label).foregroundStyle(Palette.text2).frame(maxWidth: .infinity, alignment: .leading)
            DurationText(value, size: 20)
            Text(of).font(Typo.small).foregroundStyle(Palette.text3).monospacedDigit().frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// Měřidlo dneška: tři tenké oblouky (270°, otevřené dole) se stupnicí po čtvrtinách.
struct DayGauge: View {
    struct Ring {
        let label: String
        let value: Double
        let color: Color
    }

    let rings: [Ring]
    let valueText: String
    let sub: String

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let scale = size.width / 230
                var ticks = Path()
                for f in [0, 0.25, 0.5, 0.75, 1.0] {
                    let a = Angle.degrees(135 + 270 * f).radians
                    ticks.move(to: CGPoint(x: c.x + 107 * scale * cos(a), y: c.y + 107 * scale * sin(a)))
                    ticks.addLine(to: CGPoint(x: c.x + 113 * scale * cos(a), y: c.y + 113 * scale * sin(a)))
                }
                ctx.stroke(ticks, with: .color(Palette.text3.opacity(0.6)), lineWidth: 1)
                for (i, ring) in rings.enumerated() {
                    let r = CGFloat([100, 84, 68][i]) * scale
                    var track = Path()
                    track.addArc(center: c, radius: r, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
                    ctx.stroke(track, with: .color(Palette.line), lineWidth: 7 * scale)
                    let f = min(1, max(0, ring.value))
                    if f > 0.004 {
                        var arc = Path()
                        arc.addArc(center: c, radius: r, startAngle: .degrees(135), endAngle: .degrees(135 + 270 * f), clockwise: false)
                        ctx.stroke(arc, with: .color(ring.color), style: StrokeStyle(lineWidth: 7 * scale, lineCap: .butt))
                    }
                    let a = Angle.degrees(135).radians
                    ctx.draw(
                        Text(ring.label).font(.system(size: 11)).foregroundStyle(Palette.text2),
                        at: CGPoint(x: c.x + r * cos(a) + 9 * scale, y: c.y + r * sin(a) + 1),
                        anchor: .leading
                    )
                }
            }
            VStack(spacing: 2) {
                DurationText(valueText, size: valueText.count > 9 ? 30 : valueText.count > 6 ? 36 : 46)
                Text(sub).font(.system(size: 12.5)).foregroundStyle(Palette.text2)
            }
            .padding(.bottom, 10)
        }
        .frame(width: 230, height: 230)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rings.map { "\($0.label) \(Int((min(1, $0.value) * 100).rounded())) %" }.joined(separator: ", "))
    }
}

// MARK: - Týden

private struct WeekSection: View {
    let state: DashboardState

    var body: some View {
        PageSection("Tento týden", accessory: {
            Text(Format.duration(state.weekSec) + (state.weekGoalSec > 0 ? " z \(Format.duration(state.weekGoalSec))" : "")).monospacedDigit()
        }) {
            let max = Swift.max(1, state.weekDays.map(\.sec).max() ?? 1)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(state.weekDays, id: \.label) { d in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(d.isToday ? Palette.accent : Palette.panel3)
                            .frame(maxWidth: 26)
                            .frame(height: Swift.max(2, CGFloat(d.sec) / CGFloat(max) * 40))
                        Text(d.label).font(.system(size: 11)).foregroundStyle(d.isToday ? Palette.text : Palette.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(d.label): \(Format.duration(d.sec))")
                }
            }
            .frame(height: 62, alignment: .bottom)
            .padding(.bottom, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Učení po dnech tohoto týdne")

            if state.weekRows.isEmpty {
                EmptyNote("Tento týden zatím nic", systemImage: "target") { Text("Týdenní cíle se nastavují u předmětů.") }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.weekRows.enumerated()), id: \.element.id) { i, row in
                        ListRow(divider: i < state.weekRows.count - 1) {
                            SubjectTag(name: row.subject.name, color: row.subject.color).frame(width: 170, alignment: .leading)
                            ProgressLine(row.goalSec > 0 ? row.fraction : 0, color: Palette.subject(row.subject.color))
                            Text(Format.duration(row.sec) + (row.goalSec > 0 ? " z \(Format.duration(row.goalSec))" : ""))
                                .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2)
                                .frame(width: 140, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityIdentifier("dash.week")
    }
}

// MARK: - Seznamy

private struct PlanSection: View {
    let rows: [DashboardState.PlanRow]

    var body: some View {
        PageSection("Dnešní plán") {
            if rows.isEmpty {
                EmptyNote("Na dnešek nic", systemImage: "calendar")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, b in
                        ListRow(divider: i < rows.count - 1) {
                            Text(b.time).font(Typo.serifNumber(18)).frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                SubjectTag(name: b.subject.name, color: b.subject.color)
                                if !b.title.isEmpty { Text(b.title).font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(b.durationMin) min").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                            if b.done { Image(systemName: "checkmark").foregroundStyle(Palette.success).accessibilityLabel("Hotovo") }
                        }
                        .opacity(b.done ? 0.5 : 1)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct DueSection: View {
    let rows: [DashboardState.TopicRow]

    var body: some View {
        PageSection("K zopakování", accessory: { if !rows.isEmpty { Text("\(rows.count)") } }) {
            if rows.isEmpty {
                EmptyNote("Dnes nic k opakování", systemImage: "checkmark") { Text("Témata z časovače se sem vrátí ve správný čas.") }
            } else {
                VStack(spacing: 0) {
                    let shown = Array(rows.prefix(6))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                        ListRow(divider: i < shown.count - 1) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).lineLimit(1)
                                HStack(spacing: 6) {
                                    SubjectTag(name: t.subject.name, color: t.subject.color)
                                    if t.overdueDays > 0 { Text("+\(t.overdueDays) d").foregroundStyle(Palette.danger).monospacedDigit() }
                                }
                                .font(Typo.small).foregroundStyle(Palette.text3)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct ExamsSection: View {
    let rows: [DashboardState.ExamRow]

    var body: some View {
        PageSection("Zkoušky") {
            if rows.isEmpty {
                EmptyNote("Žádné zkoušky", systemImage: "graduationcap")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                        ListRow(divider: i < rows.count - 1) {
                            VStack(spacing: 0) {
                                Text("\(e.daysLeft)").font(Typo.serifNumber(24))
                                    .foregroundStyle(e.daysLeft <= 3 ? Palette.danger : e.daysLeft <= 10 ? Palette.warn : Palette.text)
                                Text(Format.plural(e.daysLeft, "den", "dny", "dní")).font(.system(size: 10.5)).foregroundStyle(Palette.text3)
                            }
                            .frame(width: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name).lineLimit(1)
                                SubjectTag(name: e.subject.name, color: e.subject.color).font(Typo.small).foregroundStyle(Palette.text3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(e.day).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct RecentSection: View {
    let rows: [SessionRow]
    let openHistory: () -> Void

    var body: some View {
        PageSection("Poslední sezení", accessory: { Button("Historie", action: openHistory).buttonStyle(.link) }) {
            if rows.isEmpty {
                EmptyNote("Zatím žádná sezení", systemImage: "book")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                    GridRow {
                        ForEach(["Kdy", "Předmět", "Téma", "Režim", "Soustředění", "Čas"], id: \.self) { h in
                            Text(h).gridColumnAlignment(h == "Soustředění" || h == "Čas" ? .trailing : .leading)
                        }
                    }
                    .font(Typo.small).foregroundStyle(Palette.text3)
                    .padding(.bottom, 6)
                    ForEach(rows) { s in
                        Divider().overlay(Palette.line).gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text(s.when).monospacedDigit().foregroundStyle(Palette.text3)
                            SubjectTag(name: s.subject.name, color: s.subject.color)
                            Text(s.topic.isEmpty ? "—" : s.topic).foregroundStyle(s.topic.isEmpty ? Palette.text3 : Palette.text2).lineLimit(1)
                            Text(s.mode).foregroundStyle(Palette.text3)
                            Text(s.focus.map { "\($0)/5" } ?? "—").monospacedDigit()
                            Text(s.duration).monospacedDigit()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .font(.system(size: 13))
                .accessibilityIdentifier("dash.recent")
            }
        }
    }
}

// MARK: - Bez dat

private struct ConnectPrompt: View {
    let openSettings: () -> Void

    var body: some View {
        PageSection("Připoj svoje data") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Aplikace pro Mac používá stejná data jako webová aplikace – soukromé repo na GitHubu. Stačí vložit token a data se načtou.")
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Připojit GitHub", action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .accessibilityIdentifier("dash.connect")
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }
}
