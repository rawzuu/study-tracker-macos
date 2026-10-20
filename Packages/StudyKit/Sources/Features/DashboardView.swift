import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Dnes: seznam dne (bloky po částech dne, běžící blok, volné chvíle s návrhem) a vedle souhrn
/// dneška, týdne, předmětů a zkoušek.
public struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @Environment(Advisor.self) private var advisor
    @Environment(Toasts.self) private var toasts
    @Environment(AppleCalendarSync.self) private var appleCalendar
    @State private var dayPlan: DayPlanRequest?
    let openPage: (String) -> Void

    /// Bez posouvání, s pevným „teď“ a šířkou – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private var snapshot: (now: Int, width: CGFloat)?

    public init(openPage: @escaping (String) -> Void = { _ in }) {
        self.openPage = openPage
    }

    init(snapshotNow: Int, width: CGFloat = 1440) {
        self.openPage = { _ in }
        self.snapshot = (snapshotNow, width)
    }

    public var body: some View {
        Group {
            if let snapshot {
                page(now: snapshot.now, width: snapshot.width)
            } else {
                // Každou minutu se přepočítá „teď“ (zmeškané bloky, volné chvíle, série).
                TimelineView(.everyMinute) { context in
                    GeometryReader { proxy in
                        ScrollView { page(now: Int(context.date.timeIntervalSince1970 * 1000), width: proxy.size.width) }
                    }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Dnes")
        .sheet(item: $dayPlan, onDismiss: { toasts.presentAfterSheet() }) { DayPlanSheet(plan: $0.plan) }
    }

    /// Otevře ranní plán s čerstvým návrhem.
    private func planDay() {
        dayPlan = DayPlanRequest(plan: DayPlanSheet.proposal(store, calendar: appleCalendar))
    }

    private func page(now: Int, width: CGFloat) -> some View {
        let summary = DashboardState(document: store.document, now: now, clock: store.clock)
        let today = TodayState(document: store.document, now: now, clock: store.clock,
                               external: appleCalendar.busyEvents.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end, color: $0.color) },
                               running: running(now: now), recommendations: advisor.recommendations(now: now))
        let metrics = PageMetrics(width: width)
        let list = listColumn(summary, today, now: now, metrics: metrics)
        let side = SummaryColumn(state: summary, now: now, openPage: openPage)
        return Group {
            if metrics.size == .compact {
                VStack(alignment: .leading, spacing: 40) {
                    list
                    side.padding(.horizontal, metrics.padding).padding(.bottom, 40)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    list.frame(maxWidth: metrics.size == .wide ? 1180 : .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    side
                        .padding(.horizontal, metrics.size == .wide ? 44 : 32)
                        .padding(.top, 60)
                        .padding(.bottom, 40)
                        .frame(width: metrics.size == .wide ? 460 : 340, alignment: .topLeading)
                        .frame(minHeight: 600, alignment: .top)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
                }
            }
        }
    }

    private func listColumn(_ summary: DashboardState, _ today: TodayState, now: Int, metrics: PageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader("Dnes", subtitle: subtitle(summary, today), glyph: .today(day: store.clock.calendar.component(.day, from: store.clock.date(now)))) {
                Button("Ranní plán", action: planDay)
                    .buttonStyle(.study(.normal, size: .small))
                    .accessibilityIdentifier("dash.planDay")
                if timer.state.status == .idle {
                    Button("Začít učení") { openPage("casovac") }
                        .buttonStyle(.study(.normal, size: .small))
                        .accessibilityIdentifier("dash.startLearning")
                }
            }
            SyncBanner(openSettings: { openPage("nastaveni") })
            if advisor.showsMorningPrompt(now: now) {
                Banner("Dobré ráno – naplánuj si dnešek. Navrhnu bloky podle zkoušek a cílů, ty jen potvrdíš.", systemImage: "sunrise", tone: .accent) {
                    Button("Naplánovat den", action: planDay)
                        .buttonStyle(.study(.normal, size: .small))
                        .accessibilityIdentifier("dash.morning.plan")
                    Button { advisor.dismissMorningPrompt(now: now) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.study(.ghost, size: .small))
                        .help("Skrýt na dnešek")
                        .accessibilityLabel("Skrýt")
                }
                .accessibilityIdentifier("dash.morning")
            }
            if summary.isEmpty && !store.isConnected {
                ConnectPrompt(openSettings: { openPage("nastaveni") })
            } else {
                if timer.state.canSwitch {
                    NextUpSection(now: now, openTimer: { openPage("casovac") })
                }
                TodayList(state: today, now: now, openTimer: { openPage("casovac") }, planDay: planDay)
            }
        }
        .padding(.leading, metrics.size == .compact ? metrics.padding : 64)
        .padding(.trailing, metrics.size == .compact ? metrics.padding : 48)
        .padding(.top, 48)
        .padding(.bottom, 48)
    }

    private func subtitle(_ s: DashboardState, _ today: TodayState) -> String {
        var parts = [s.title]
        if today.goalSec > 0 {
            parts.append(today.remainingSec > 0 ? "do denního cíle zbývá \(Format.duration(today.remainingSec))" : "denní cíl splněn")
        }
        if let intention = s.intention { parts.append("záměr: \(intention)") }
        return parts.joined(separator: " · ")
    }

    /// Běžící nebo pozastavený blok učení jako úsek dne (začátek a předpokládaný konec).
    private func running(now: Int) -> TodayState.Running? {
        let s = timer.state
        guard s.isStudying else { return nil }
        let left = s.remaining(at: now) ?? 25 * StudyClock.minute
        return .init(planBlockId: s.planBlockId, subjectId: s.subjectId, topic: s.topic, start: s.workStartedAt ?? now, end: now + left)
    }
}

/// Otevřený ranní plán s návrhem z okamžiku otevření.
struct DayPlanRequest: Identifiable {
    let id = UUID()
    let plan: [DayPlan.PlannedDay]
}

// MARK: - Seznam dne

/// Části dne s bloky, obsazeným časem a volnými chvílemi; pod nimi zítřek.
private struct TodayList: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    @Environment(Toasts.self) private var toasts
    let state: TodayState
    let now: Int
    let openTimer: () -> Void
    let planDay: () -> Void
    @State private var showsTomorrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if state.sections.isEmpty {
                EmptyNote("Na dnešek nic v plánu", systemImage: "calendar") {
                    Button("Naplánovat den", action: planDay).buttonStyle(.study(.normal, size: .small)).padding(.top, 6)
                }
            }
            ForEach(state.sections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    ListHeading(section.part.title, meta: section.meta) {
                        if section.part == .evening { Image(systemName: "moon.fill").font(.system(size: 11)) }
                    }
                    ForEach(section.entries) { entry in
                        switch entry {
                        case .item(let item) where item.status == .running:
                            RunningCard(item: item, openTimer: openTimer).padding(.vertical, 6)
                        case .item(let item):
                            ItemRow(item: item, start: start, toggle: toggle)
                        case .busy(let busy):
                            BusyRow(busy: busy)
                        case .gap(let gap):
                            GapRow(gap: gap, plan: plan)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(section.part.title)
            }
            if !state.tomorrow.isEmpty {
                tomorrow
            }
        }
        .accessibilityIdentifier("dash.plan")
    }

    private var tomorrow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.18)) { showsTomorrow.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showsTomorrow ? 90 : 0))
                    Text("Zítra").font(.system(size: 14, weight: .semibold))
                    Text(meta(state.tomorrow)).font(Typo.small).foregroundStyle(Palette.text3)
                }
                .foregroundStyle(Palette.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dash.tomorrow")
            if showsTomorrow {
                ForEach(state.tomorrow) { ItemRow(item: $0, start: nil, toggle: nil) }
                    .padding(.top, 4)
            }
        }
    }

    private func meta(_ items: [TodayState.Item]) -> String {
        "\(items.count) \(Format.plural(items.count, "blok", "bloky", "bloků")) · \(Format.duration(items.reduce(0) { $0 + $1.durationMin } * 60))"
    }

    /// Spustit časovač z bloku plánu (předmět, téma z názvu, odkaz na blok – po uložení se odškrtne).
    private func start(_ item: TodayState.Item) {
        timer.setup(TimerSetup(subjectId: item.subject.id, topic: item.topic, planBlockId: item.planBlockId))
        openTimer()
    }

    /// Odškrtnutí bloku v seznamu (jako „Hotovo“ v kalendáři, bez zápisu času).
    private func toggle(_ item: TodayState.Item) {
        guard let id = item.planBlockId, var block = store.document.record(PlanBlock.self, id: id) else { return }
        block.done.toggle()
        store.upsert(block)
    }

    /// Návrh z volné chvíle jako nový blok plánu (s možností vrátit).
    private func plan(_ s: TodayState.Suggestion) {
        let id = PlanBlock.newID()
        store.upsert(PlanBlock(raw: [
            "id": .string(id), "subjectId": .string(s.subject.id), "title": .string(s.title),
            "start": .number(Double(s.start)), "durationMin": .number(Double(s.minutes)), "done": false,
            "note": .string(s.reasons.joined(separator: " · ")),
        ]))
        toasts.show("Blok naplánován na \(Format.time(s.start, clock: store.clock))") { store.remove(.planBlocks, id: id) }
    }
}

/// Řádek bloku nebo sezení: políčko, název, předmět, blízká zkouška, čas a délka.
private struct ItemRow: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    let item: TodayState.Item
    let start: ((TodayState.Item) -> Void)?
    let toggle: ((TodayState.Item) -> Void)?
    @State private var hovering = false

    var body: some View {
        let done = item.status == .done
        HStack(spacing: 12) {
            Button { toggle?(item) } label: { BlockCheck(check) }
                .buttonStyle(.plain)
                .disabled(toggle == nil || item.planBlockId == nil)
                .help(done ? "Označit jako nehotové" : "Označit jako hotové")
                .accessibilityLabel(done ? "Hotovo" : "Označit jako hotové")
            Text(item.title.isEmpty ? item.subject.name : item.title)
                .font(.system(size: 14))
                .foregroundStyle(done || item.status == .missed ? Palette.text3 : Palette.text)
                .lineLimit(1)
                .layoutPriority(1)
            if !item.title.isEmpty {
                SubjectCapsule(name: item.subject.name, color: item.subject.color, dimmed: done)
            }
            if let hint = item.examHint, !done {
                Label(hint, systemImage: "flag").font(.system(size: 12)).foregroundStyle(Palette.danger).lineLimit(1)
            }
            Spacer(minLength: 12)
            if item.status == .missed {
                Text("zmeškáno").font(Typo.small).foregroundStyle(Palette.text3)
            }
            Text("\(Format.time(item.start, clock: store.clock)) · \(item.durationMin) min")
                .font(.system(size: 12.5)).monospacedDigit()
                .foregroundStyle(done ? Palette.text3 : Palette.text2)
            if let start, !done, item.planBlockId != nil, timer.state.canSwitch {
                Button { start(item) } label: { Image(systemName: "play.fill").font(.system(size: 9)) }
                    .buttonStyle(.study(hovering ? .normal : .ghost, size: .small))
                    .help("Spustit časovač")
                    .accessibilityLabel("Spustit časovač")
                    .accessibilityIdentifier("plan.start.\(item.planBlockId ?? item.id)")
            }
        }
        .frame(minHeight: 34)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.\(item.id)")
    }

    private var check: BlockCheck.State {
        switch item.status {
        case .done: .done
        case .missed: .missed
        case .open, .running: .open
        }
    }
}

/// Běžící blok rozbalený jako karta: název, předmět, živý čas, popis a ovládání časovače.
private struct RunningCard: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    let item: TodayState.Item
    let openTimer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                liveCheck
                Text(item.title.isEmpty ? item.subject.name : item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if !item.title.isEmpty { SubjectCapsule(name: item.subject.name, color: item.subject.color) }
                Spacer(minLength: 12)
                liveTime
            }
            Text(description(timer.state))
                .font(.system(size: 13)).foregroundStyle(Palette.text2)
                .padding(.leading, 28).padding(.top, 8)
            HStack(spacing: 8) {
                TimerControls(size: .small)
                Spacer(minLength: 8)
                Button("Otevřít časovač", action: openTimer).buttonStyle(.study(.ghost, size: .small))
            }
            .padding(.leading, 28).padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        .padding(.horizontal, -16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dash.timer")
    }

    @ViewBuilder private var liveCheck: some View {
        if timer.state.status == .running, let start = timer.state.segmentStart {
            TimelineView(.periodic(from: Date(timeIntervalSince1970: Double(start) / 1000), by: 15)) { context in
                BlockCheck(.running(timer.state.progress(at: Int(context.date.timeIntervalSince1970 * 1000))))
            }
        } else {
            BlockCheck(.running(timer.state.progress(at: timer.currentTime())))
        }
    }

    @ViewBuilder private var liveTime: some View {
        if timer.state.status == .running, let start = timer.state.segmentStart {
            TimelineView(.periodic(from: Date(timeIntervalSince1970: Double(start) / 1000), by: 1)) { context in
                time(Int(context.date.timeIntervalSince1970 * 1000))
            }
        } else {
            time(timer.currentTime())
        }
    }

    private func time(_ now: Int) -> some View {
        let s = timer.state
        return Text(Format.clock(ms: s.remaining(at: now) ?? s.elapsed(at: now)))
            .font(Typo.number(13.5))
            .foregroundStyle(s.status == .paused ? Palette.text2 : Palette.accent)
            .padding(.horizontal, 8).frame(height: 24)
            .background(s.status == .paused ? Palette.panel2 : Palette.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityIdentifier("dash.timer.time")
    }

    private func description(_ s: TimerState) -> String {
        let now = timer.currentTime()
        var parts = [timer.mode.name]
        if s.status == .paused { parts.insert("Pozastaveno", at: 0) }
        if let left = s.remaining(at: now) { parts.append("končí v \(Format.time(now + left, clock: store.clock))") }
        return parts.joined(separator: " · ")
    }
}

/// Obsazený čas (výuka, událost z kalendáře) – tichý řádek, ať je jasné, proč tu není volno.
private struct BusyRow: View {
    @Environment(AppStore.self) private var store
    let busy: TodayState.Busy

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let color = busy.color {
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.subject(color)).frame(width: 3, height: 14)
                } else {
                    Image(systemName: "graduationcap").font(.system(size: 11)).foregroundStyle(Palette.text3)
                }
            }
            .frame(width: 16, height: 16)
            Text(busy.title).font(.system(size: 13.5)).foregroundStyle(Palette.text2).lineLimit(1)
            Spacer(minLength: 12)
            Text("\(Format.time(busy.start, clock: store.clock))–\(Format.time(busy.end, clock: store.clock))")
                .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Palette.text3)
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

/// Volná chvíle: s návrhem bloku a tlačítkem „Naplánovat“, jinak jen tichá poznámka.
private struct GapRow: View {
    @Environment(AppStore.self) private var store
    let gap: TodayState.Gap
    let plan: (TodayState.Suggestion) -> Void

    var body: some View {
        let clock = store.clock
        let range = "\(Format.time(gap.start, clock: clock))–\(Format.time(gap.end, clock: clock))"
        if let s = gap.suggestion {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    BlockCheck(.suggested)
                    ColorMark(color: s.subject.color).padding(.trailing, -4)
                    (Text(s.subject.name).foregroundStyle(Palette.text2) + Text(s.title.isEmpty ? "" : "  \(s.title)").foregroundStyle(Palette.text3))
                        .font(.system(size: 14)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 12)
                    Button("Naplánovat na \(Format.time(s.start, clock: clock))") { plan(s) }
                        .buttonStyle(.link)
                        .font(.system(size: 12.5, weight: .medium))
                        .accessibilityIdentifier("gap.plan.\(gap.start)")
                }
                .frame(minHeight: 34)
                Text(["Volno \(range)", "\(s.minutes) min", s.reasons.first].compactMap { $0 }.joined(separator: " · "))
                    .font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1)
                    .padding(.leading, 28)
                    .padding(.bottom, 4)
            }
            .accessibilityElement(children: .contain)
        } else {
            Text("Volno \(range) · \(Format.duration((gap.end - gap.start) / 1000))")
                .font(Typo.small).foregroundStyle(Palette.text3)
                .padding(.leading, 28)
                .frame(minHeight: 28, alignment: .leading)
        }
    }
}

// MARK: - Souhrn

/// Pravý sloupec: dnešek, časovač, týden, předměty, zkoušky a poslední sezení – jen text a tenké čáry.
private struct SummaryColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(AnkiSync.self) private var anki
    let state: DashboardState
    let now: Int
    let openPage: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            TodaySummary(state: state)
            DashTimer(openTimer: { openPage("casovac") })
            // Anki jako na webu: když je propojená, nebo už je známý stav z jiného zařízení.
            if anki.enabled || AnkiImport.today(store.document, now: now, clock: store.clock) != nil { AnkiSummary(now: now) }
            WeekSummary(state: state)
            if !state.weekRows.isEmpty { SubjectsSummary(rows: state.weekRows) }
            if !state.exams.isEmpty { ExamsSummary(rows: state.exams) }
            if !state.recent.isEmpty { RecentSummary(rows: Array(state.recent.prefix(4)), openHistory: { openPage("historie") }) }
        }
        .font(.system(size: 13))
    }
}

struct SummaryTitle: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Palette.text2) }
        }
    }
}

private struct TodaySummary: View {
    let state: DashboardState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DurationText(Format.duration(state.todaySec), size: 24)
            Text(line).font(.system(size: 13)).foregroundStyle(Palette.text2)
            if state.goalSec > 0 {
                ProgressLine(Double(state.todaySec) / Double(state.goalSec), color: state.todaySec >= state.goalSec ? Palette.success : Palette.accent)
                    .padding(.top, 10)
            }
            if let focus = state.focus7 {
                Text("Soustředění \(Format.decimal(focus)) z 5 za 7 dní").font(Typo.small).foregroundStyle(Palette.text3).padding(.top, 8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dash.today")
    }

    private var line: String {
        var parts: [String] = []
        if state.goalSec > 0 { parts.append(state.todaySec >= state.goalSec ? "dnes, cíl splněn" : "dnes ze \(Format.duration(state.goalSec))") } else { parts.append("dnes") }
        let streak = state.streak.current
        if streak > 0 { parts.append("série \(streak) \(Format.plural(streak, "den", "dny", "dní"))") }
        return parts.joined(separator: " · ")
    }
}

private struct WeekSummary: View {
    let state: DashboardState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SummaryTitle("Tento týden", detail: Format.duration(state.weekSec) + (state.weekGoalSec > 0 ? " z \(Format.duration(state.weekGoalSec))" : ""))
            let top = max(1, state.weekDays.map(\.sec).max() ?? 1)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(state.weekDays, id: \.label) { d in
                    VStack(spacing: 6) {
                        Capsule()
                            .fill(d.isToday ? Palette.accent : Palette.panel3)
                            .frame(width: 6, height: max(3, CGFloat(d.sec) / CGFloat(top) * 44))
                        Text(String(d.label.prefix(1))).font(.system(size: 10.5, weight: d.isToday ? .bold : .regular))
                            .foregroundStyle(d.isToday ? Palette.text : Palette.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(d.label): \(Format.duration(d.sec))")
                }
            }
            .frame(height: 64, alignment: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.weekDays.map { "\($0.label) \(Format.duration($0.sec))" }.joined(separator: ", "))
            if let delta = state.weekDelta {
                Text("\(delta >= 0 ? "+" : "−")\(Int((abs(delta) * 100).rounded())) % proti minulému týdnu")
                    .font(Typo.small).foregroundStyle(Palette.text3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dash.week")
    }
}

private struct SubjectsSummary: View {
    let rows: [DashboardState.SubjectProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SummaryTitle("Předměty")
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    ProgressPie(row.fraction, color: Palette.subject(row.subject.color))
                    Text(row.subject.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.duration(row.sec) + (row.goalSec > 0 ? " z \(Format.duration(row.goalSec))" : ""))
                        .monospacedDigit().foregroundStyle(Palette.text2)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct ExamsSummary: View {
    let rows: [DashboardState.ExamRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SummaryTitle("Zkoušky")
            ForEach(rows) { e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(e.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(when(e)).monospacedDigit()
                        .foregroundStyle(e.daysLeft <= 3 ? Palette.danger : e.daysLeft <= 10 ? Palette.warn : Palette.text2)
                }
                .help("\(e.subject.name) · \(e.day)")
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func when(_ e: DashboardState.ExamRow) -> String {
        e.daysLeft == 0 ? "dnes" : e.daysLeft == 1 ? "zítra" : "za \(e.daysLeft) \(Format.plural(e.daysLeft, "den", "dny", "dní"))"
    }
}

private struct RecentSummary: View {
    let rows: [SessionRow]
    let openHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SummaryTitle("Naposledy")
                Button("Historie", action: openHistory).buttonStyle(.link).font(.system(size: 12.5))
            }
            ForEach(rows) { s in
                HStack(spacing: 10) {
                    Circle().fill(Palette.subject(s.subject.color)).frame(width: 7, height: 7)
                    Text(s.topic.isEmpty ? s.subject.name : s.topic).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(s.duration).monospacedDigit().foregroundStyle(Palette.text2)
                }
                .help("\(s.subject.name) · \(s.when)")
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("dash.recent")
    }
}

/// Časovač v souhrnu: stav a čas; když blok běží, ovládání je v kartě v seznamu.
private struct DashTimer: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    let openTimer: () -> Void

    var body: some View {
        let state = timer.state
        if !state.isStudying {
            // Klik kamkoli otevře časovač; čas zůstává samostatný text (čtou ho testy i VoiceOver).
            HStack(spacing: 10) {
                PageGlyphView(.timer, size: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status(state)).foregroundStyle(Palette.text)
                    Text(detail(state)).font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(clock(state)).font(Typo.number(13.5)).foregroundStyle(state.phase == .work ? Palette.text : Palette.breakColor)
                    .accessibilityIdentifier("dash.timer.time")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openTimer)
            .help("Otevřít časovač")
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Otevřít časovač", openTimer)
            .accessibilityIdentifier("dash.timer")
        }
    }

    private func clock(_ s: TimerState) -> String {
        let now = timer.currentTime()
        return s.status == .idle ? Format.clock(ms: timer.mode.workDurationMs ?? 0) : Format.clock(ms: s.remaining(at: now) ?? s.elapsed(at: now))
    }

    private func status(_ s: TimerState) -> String {
        switch s.status {
        case .idle: "Časovač připravený"
        case .paused: "Pozastaveno"
        case .ready: s.phase == .work ? "Připraveno na další blok" : "Připravená pauza"
        case .running: s.phase == .work ? "Učení" : "Pauza"
        }
    }

    private func detail(_ s: TimerState) -> String {
        let subject = s.subjectId.isEmpty ? nil : store.document.record(Subject.self, id: s.subjectId)?.name
        return timer.mode.name + (subject.map { " · \($0)" } ?? "")
    }
}

// MARK: - Bez dat

private struct ConnectPrompt: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Připoj svoje data").font(Typo.sectionTitle)
            Text("Aplikace pro Mac používá stejná data jako webová aplikace – soukromé repo na GitHubu. Stačí vložit token a data se načtou.")
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Připojit GitHub", action: openSettings)
                .buttonStyle(.primary)
                .accessibilityIdentifier("dash.connect")
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
