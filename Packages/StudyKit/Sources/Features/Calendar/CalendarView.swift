import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Kalendář (`PlannerPage` na webu): odučený čas (plná barva) a plán (obrys) v týdnu nebo měsíci,
/// plán vs. realita a nadcházející zkoušky.
public struct CalendarView: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer
    let openPage: (String) -> Void

    @State private var mode: Mode = .week
    @State private var layer: CalendarLayer = .all
    /// Zobrazený týden a měsíc; `nil` = aktuální.
    @State private var weekStart: Int?
    @State private var monthStart: Int?
    @State private var sheet: CalendarSheet?

    /// Bez posouvání a s pevným „teď“ – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private var snapshotNow: Int?

    enum Mode: String, CaseIterable {
        case week = "Týden", month = "Měsíc"
    }

    public init(openPage: @escaping (String) -> Void = { _ in }) {
        self.openPage = openPage
    }

    init(snapshotNow: Int, mode: Mode = .week) {
        self.openPage = { _ in }
        self.snapshotNow = snapshotNow
        _mode = State(initialValue: mode)
    }

    public var body: some View {
        Group {
            if let snapshotNow {
                page(now: snapshotNow)
            } else {
                // Běžící blok roste po čtvrtminutách, jinak stačí jednou za minutu (čára „teď“).
                TimelineView(.periodic(from: .now, by: timer.state.isStudying ? 15 : 60)) { context in
                    ScrollView { page(now: Int(context.date.timeIntervalSince1970 * 1000)) }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Kalendář")
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
    }

    // MARK: - Stránka

    private func page(now: Int) -> some View {
        let clock = store.clock
        let week = weekStart ?? clock.startOfWeek(now)
        return VStack(alignment: .leading, spacing: 32) {
            PageHeader("Kalendář", subtitle: subtitle) { headerButtons(now: now, week: week) }
            if store.sync.mode == .readOnly && store.isConnected {
                Banner("Režim jen pro čtení: úpravy plánu se uloží jen na tomto Macu. Na GitHub odejdou, až v Nastavení vypneš „Jen čtení“.",
                       systemImage: "lock", tone: .warn)
            }
            VStack(alignment: .leading, spacing: 14) {
                switch mode {
                case .week:
                    let state = CalendarWeekState(document: store.document, weekStart: week, layer: layer, live: timer.state, now: now, clock: clock)
                    calendarHeader(title: state.title, isCurrent: state.isCurrentWeek, summary: "odučeno \(state.studied) · plán \(state.planned)") {
                        weekStart = clock.addDays(week, $0 * 7)
                    }
                    WeekGrid(state: state, now: now, clock: clock, actions: gridActions(now: now), scrolls: snapshotNow == nil)
                    WeekLegend(state: state)
                case .month:
                    let month = monthStart ?? clock.startOfMonth(now)
                    let state = CalendarMonthState(document: store.document, monthStart: month, layer: layer, now: now, clock: clock)
                    calendarHeader(title: state.title, isCurrent: state.isCurrentMonth, summary: nil) {
                        monthStart = CalendarMonthState.shift(month, by: $0, clock: clock)
                    }
                    MonthGrid(state: state) { day in
                        weekStart = clock.startOfWeek(day)
                        mode = .week
                    }
                }
            }
            FlowRow {
                PlanVsRealitySection(rows: PlanVsRealityRow.rows(document: store.document, weekStart: week, clock: clock),
                                     isCurrentWeek: week == clock.startOfWeek(now))
                    .frame(minWidth: 380, maxWidth: .infinity)
                ExamsListSection(rows: UpcomingExamRow.rows(document: store.document, now: now, clock: clock),
                                 add: { sheet = .init(.exam(ExamDraft(newAt: now, clock: clock))) },
                                 open: openExam)
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(maxWidth: 2200, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let done = store.document.settings.blockDoneLogs ? ", nebo tlačítkem Hotovo u bloku" : ""
        return "Plná barva = odučený čas, obrys = plán. Čas se zapíše z časovače\(done). Klikni do prázdna pro nový záznam, "
            + "plán přesouvej tažením a délku měň tažením za spodní okraj."
    }

    @ViewBuilder
    private func headerButtons(now: Int, week: Int) -> some View {
        let clock = store.clock
        HStack(spacing: 8) {
            Button { sheet = .init(.timetable) } label: { Label("Rozvrh", systemImage: "building.columns") }
                .buttonStyle(.denik(.normal))
                .accessibilityIdentifier("calendar.timetable")
            Button { sheet = .init(.exam(ExamDraft(newAt: now, clock: clock))) } label: { Label("Zkouška", systemImage: "graduationcap") }
                .buttonStyle(.denik(.normal))
                .accessibilityIdentifier("calendar.addExam")
            Button { sheet = .init(.session(SessionDraft(newAt: now - StudyClock.hour, now: now, clock: clock))) } label: {
                Label("Zapsat odučené", systemImage: "square.and.pencil")
            }
            .buttonStyle(.denik(.normal))
            .accessibilityIdentifier("calendar.logSession")
            Button { sheet = .init(.block(PlanBlockDraft(newAt: max(now, week + 9 * StudyClock.hour), clock: clock))) } label: {
                Label("Naplánovat", systemImage: "plus")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("calendar.addBlock")
        }
        .labelStyle(.titleAndIcon)
    }

    /// Záhlaví kalendáře: šipky, rozsah, „Dnes“ a vpravo filtr a přepínač týden/měsíc.
    private func calendarHeader(title: String, isCurrent: Bool, summary: String?, shift: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.denik(.normal, size: .small)).help("Předchozí").accessibilityLabel("Předchozí")
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.denik(.normal, size: .small)).help("Další").accessibilityLabel("Další")
            }
            Text(title).font(Typo.sectionTitle).lineLimit(1).accessibilityIdentifier("calendar.range")
            if !isCurrent {
                Button("Dnes") {
                    weekStart = nil
                    monthStart = nil
                }
                .buttonStyle(.denik(.ghost, size: .small))
            }
            Spacer(minLength: 12)
            if let summary {
                Text(summary).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2)
            }
            Picker("Zobrazit", selection: $layer) {
                ForEach(CalendarLayer.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("calendar.layer")
            Picker("Pohled", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("calendar.mode")
        }
    }

    // MARK: - Akce

    private func gridActions(now: Int) -> WeekGridActions {
        let clock = store.clock
        return WeekGridActions(
            emptySlot: { start in
                switch layer {
                case .plan: sheet = .init(.block(PlanBlockDraft(newAt: start, clock: clock)))
                case .done: sheet = .init(.session(SessionDraft(newAt: start, now: now, clock: clock)))
                case .all: sheet = .init(.choose(start: start))
                }
            },
            open: { item in
                switch item.source {
                case .block(let id):
                    if let b = store.document.record(PlanBlock.self, id: id) { sheet = .init(.block(PlanBlockDraft(editing: b, clock: clock))) }
                case .session(let id):
                    if let s = store.document.record(Session.self, id: id) { sheet = .init(.session(SessionDraft(editing: s, clock: clock))) }
                case .lecture(let timetableId, let key):
                    sheet = .init(.lecture(timetableId: timetableId, key: key))
                case .live:
                    break
                }
            },
            exam: openExam,
            move: { id, drag in
                guard var b = store.document.record(PlanBlock.self, id: id) else { return }
                if let dur = drag.durDelta {
                    b.durationMin += dur
                } else {
                    b.start = drag.movedStart(b.start, clock: clock)
                }
                store.upsert(b)
            }
        )
    }

    private func openExam(_ id: String) {
        guard let exam = store.document.record(Exam.self, id: id) else { return }
        sheet = .init(.exam(ExamDraft(editing: exam, now: store.nowMs, clock: store.clock)))
    }

    @ViewBuilder
    private func sheetContent(_ sheet: CalendarSheet) -> some View {
        switch sheet.kind {
        case .choose(let start): NewEntrySheet(start: start, openTimer: { openPage("casovac") })
        case .block(let draft): PlanBlockEditor(draft: draft, openTimer: { openPage("casovac") })
        case .session(let draft): SessionEditor(draft: draft)
        case .exam(let draft): ExamEditor(draft: draft)
        case .timetable: TimetableSheet()
        case .lecture(let timetableId, let key): LectureSheet(timetableId: timetableId, key: key) { self.sheet = .init(.timetable) }
        }
    }
}

/// Otevřené okno kalendáře. Každé otevření má vlastní id, takže stejný formulář jde otevřít znovu.
struct CalendarSheet: Identifiable {
    enum Kind {
        case choose(start: Int)
        case block(PlanBlockDraft)
        case session(SessionDraft)
        case exam(ExamDraft)
        case timetable
        case lecture(timetableId: String, key: String)
    }

    let id = UUID()
    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

// MARK: - Nový záznam z prázdného místa

/// Klik do prázdna ve „Vše“: naplánovat, nebo zapsat odučené (`choose` na webu).
private struct NewEntrySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let start: Int
    let openTimer: () -> Void
    @State private var choice: Choice?

    private enum Choice { case plan, log }

    var body: some View {
        let clock = store.clock
        switch choice {
        case .plan: PlanBlockEditor(draft: PlanBlockDraft(newAt: start, clock: clock), openTimer: openTimer)
        case .log: SessionEditor(draft: SessionDraft(newAt: start, now: store.nowMs, clock: clock))
        case nil:
            EditorSheet("\(Format.capitalized(Format.date(start, .weekdayDayNumericMonth, clock: clock))) · \(Format.time(start, clock: clock))") {
                HStack(spacing: 10) {
                    option(key: .plan, title: "Naplánovat", detail: "Záměr – blok učení do plánu")
                    option(key: .log, title: "Zapsat odučené", detail: "Učení bez spuštěného časovače")
                }
            } footer: {
                Spacer()
                Button("Zrušit") { dismiss() }.buttonStyle(.denik(.ghost)).keyboardShortcut(.cancelAction)
            }
        }
    }

    private func option(key: Choice, title: String, detail: String) -> some View {
        Button { choice = key } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(key == .log ? Palette.text2 : .clear)
                    .overlay {
                        if key == .plan { RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.text2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                    }
                    .frame(width: 34, height: 22)
                Text(title).fontWeight(.semibold).foregroundStyle(Palette.text)
                Text(detail).font(Typo.small).foregroundStyle(Palette.text3)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.lineStrong))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(key == .plan ? "choose.plan" : "choose.log")
    }
}

// MARK: - Legenda, plán vs. realita, zkoušky

private struct WeekLegend: View {
    let state: CalendarWeekState

    var body: some View {
        WrapLayout(spacing: 16, lineSpacing: 8) {
            key("odučeno") { RoundedRectangle(cornerRadius: 2).fill(Palette.text2) }
            key("plán") { RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.text2, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
            if state.hasLectures {
                key("výuka") {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.panel3)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.lineStrong))
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.text3).frame(width: 2) }
                }
            }
            Rectangle().fill(Palette.lineStrong).frame(width: 1, height: 14)
            if state.legend.isEmpty {
                Text("Tento týden zatím nic odučeno.").foregroundStyle(Palette.text3)
            } else {
                ForEach(state.legend) { t in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.subject(t.subject.color)).frame(width: 10, height: 10)
                        Text(t.subject.name).foregroundStyle(Palette.text)
                        Text(Format.duration(t.sec)).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                }
            }
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func key(_ label: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 6) {
            swatch().frame(width: 16, height: 10)
            Text(label).foregroundStyle(Palette.text2)
        }
    }
}

private struct PlanVsRealitySection: View {
    let rows: [PlanVsRealityRow]
    let isCurrentWeek: Bool

    var body: some View {
        PageSection("Plán vs. realita", accessory: { Text(isCurrentWeek ? "tento týden" : "vybraný týden") }) {
            if rows.isEmpty {
                EmptyNote("Tento týden zatím nic", systemImage: "calendar.badge.plus") {
                    Text("Naplánuj bloky nebo si nastav týdenní cíle u předmětů.")
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                SubjectTag(name: row.subject.name, color: row.subject.color)
                                Spacer()
                                (Text(Format.duration(row.studiedSec)).foregroundStyle(Palette.text) + Text(" " + row.detail))
                                    .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                            }
                            ProgressLine(row.fraction, color: Palette.subject(row.subject.color))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 4)
            }
        }
        .accessibilityIdentifier("calendar.planVsReality")
    }
}

private struct ExamsListSection: View {
    let rows: [UpcomingExamRow]
    let add: () -> Void
    let open: (String) -> Void

    var body: some View {
        PageSection("Zkoušky", accessory: {
            Button(action: add) { Label("Přidat", systemImage: "plus") }.buttonStyle(.denik(.ghost, size: .small))
        }) {
            if rows.isEmpty {
                EmptyNote("Žádné nadcházející zkoušky", systemImage: "graduationcap") {
                    Text("Přidej zkoušku – odpočet uvidíš tady i na přehledu.")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                        Button { open(e.id) } label: {
                            ListRow(divider: i < rows.count - 1) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(e.name).fontWeight(.semibold).foregroundStyle(Palette.text)
                                    HStack(spacing: 6) {
                                        SubjectTag(name: e.subject.name, color: e.subject.color)
                                        Text("· \(e.when)")
                                    }
                                    .font(Typo.small).foregroundStyle(Palette.text2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Chip(e.countdown, tone: e.tone == .soon ? .bad : e.tone == .near ? .warn : .neutral)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("exam.\(e.id)")
                    }
                }
            }
        }
        .accessibilityIdentifier("calendar.exams")
    }
}
