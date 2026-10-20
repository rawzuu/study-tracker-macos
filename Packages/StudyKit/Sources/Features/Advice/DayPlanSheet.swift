import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Na kolik dní ranní plán navrhuje (Mac – web plánuje jen zbytek dneška).
enum PlanSpan: String, CaseIterable, Identifiable, Sendable {
    case today, tomorrow, week, nextWeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Dnes"
        case .tomorrow: "Zítra"
        case .week: "Do neděle"
        case .nextWeek: "Příští týden"
        }
    }

    /// Začátky plánovaných dnů.
    func days(now: Int, clock: StudyClock) -> [Int] {
        let today = clock.startOfDay(now)
        let monday = clock.startOfWeek(now)
        switch self {
        case .today: return [today]
        case .tomorrow: return [clock.addDays(today, 1)]
        case .week: return (0...max(0, 6 - clock.weekdayIndex(now))).map { clock.addDays(today, $0) }
        case .nextWeek: return (7..<14).map { clock.addDays(monday, $0) }
        }
    }

    /// V neděli je „do neděle“ totéž co dnes.
    static func available(now: Int, clock: StudyClock) -> [PlanSpan] {
        clock.weekdayIndex(now) == 6 ? [.today, .tomorrow, .nextWeek] : allCases
    }
}

/// Ranní plánování (`DayPlanModal` na webu): návrh bloků na zbytek dne – na Macu i na zítřek a dny
/// dopředu –, úpravy a uložení do kalendáře.
struct DayPlanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @Environment(AppleCalendarSync.self) private var appleCalendar
    @Environment(\.dismiss) private var dismiss
    @State private var span = PlanSpan.today
    /// Kolikrát se přidal „Další blok“ (+25 min k dennímu cíli; jen u plánu jednoho dne).
    @State private var extra = 0
    @State private var plan: [DayPlan.PlannedDay]
    /// Bez posouvání – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private let scrolls: Bool

    static let durations = [15, 25, 30, 45, 50, 60, 75, 90, 120]

    /// Výška seznamu dnů: na velkém monitoru víc, na malé obrazovce tak, aby tlačítka dole zůstala vidět
    /// (okno kolem seznamu potřebuje asi 340 bodů).
    @MainActor static var daysHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(240, min(560, screen - 360))
    }

    init(plan: [DayPlan.PlannedDay], span: PlanSpan = .today, scrolls: Bool = true) {
        _plan = State(initialValue: plan)
        _span = State(initialValue: span)
        self.scrolls = scrolls
    }

    /// Návrh na dnešek, se kterým se okno otevírá.
    @MainActor static func proposal(_ store: AppStore, calendar: AppleCalendarSync, span: PlanSpan = .today, extra: Int = 0) -> [DayPlan.PlannedDay] {
        DayPlan.propose(store.document, days: span.days(now: store.nowMs, clock: store.clock), now: store.nowMs, extra: extra,
                        clock: store.clock, external: calendar.busyIntervals)
    }

    var body: some View {
        let now = store.nowMs
        let doc = store.document
        let single = plan.count == 1
        let busy = busy(doc: doc)
        EditorSheet(title(now: now), width: 760) {
            HStack(spacing: 16) {
                Picker("Plánovat", selection: Binding(get: { span }, set: { change(to: $0) })) {
                    ForEach(PlanSpan.available(now: now, clock: store.clock)) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("dayplan.span")
                Spacer(minLength: 0)
                if let day = plan.first, single {
                    summary(doc: doc, day: day)
                } else {
                    figure("navrhuji", proposedMinutes(plan) * 60).font(Typo.small).accessibilityIdentifier("dayplan.proposed")
                }
            }
            if single, let day = plan.first {
                DayAxis(items: day.items, busy: busy[day.day] ?? [], range: DayPlan.dayRange(doc.settings, day: day.day, clock: store.clock),
                        to: bounds(day, doc: doc).to, now: now, clock: store.clock)
                if day.items.isEmpty {
                    Text("Na \(span == .tomorrow ? "zítřek" : "dnešek") nic dalšího nenavrhuji – cíl je splněný nebo naplánovaný. Přidat můžeš tlačítkem „Další blok“.")
                        .font(Typo.small).foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    scrolling(maxHeight: 360) { rows(0) }
                }
            } else {
                scrolling(maxHeight: Self.daysHeight) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(plan.indices, id: \.self) { i in dayGroup(i, busy: busy[plan[i].day] ?? [], doc: doc, now: now) }
                    }
                }
            }
            dayWindow(doc.settings)
        } footer: {
            Button { propose() } label: { Label("Navrhnout znovu", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.study(.ghost))
                .accessibilityIdentifier("dayplan.again")
            Spacer()
            Button("Zrušit") { dismiss() }.buttonStyle(.study(.ghost)).keyboardShortcut(.cancelAction)
            if single {
                Button {
                    extra += 1
                    propose()
                } label: { Label("Další blok", systemImage: "plus") }
                    .buttonStyle(.study(.normal))
                    .accessibilityIdentifier("dayplan.more")
            }
            Button(action: save) { Label("Uložit do kalendáře", systemImage: "calendar.badge.checkmark") }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(proposedMinutes(plan) == 0)
                .accessibilityIdentifier("dayplan.save")
        }
    }

    private func title(now: Int) -> String {
        let clock = store.clock
        guard let first = plan.first?.day, let last = plan.last?.day else { return "Plán" }
        let range = "\(Format.date(first, .dayMonth, clock: clock)) – \(Format.date(last, .dayMonth, clock: clock))"
        switch span {
        case .today: return "Plán na dnešek · \(Format.date(now, .weekdayDayMonth, clock: clock))"
        case .tomorrow: return "Plán na zítřek · \(Format.date(first, .weekdayDayMonth, clock: clock))"
        case .week: return plan.count == 1 ? "Plán na dnešek · \(Format.date(now, .weekdayDayMonth, clock: clock))" : "Plán do neděle · \(range)"
        case .nextWeek: return "Plán na příští týden · \(range)"
        }
    }

    private func bounds(_ day: DayPlan.PlannedDay, doc: AppDocument) -> (day: Int, from: Int, to: Int) {
        DayPlan.dayBounds(doc.settings, now: day.now, clock: store.clock)
    }

    /// Obsazený čas všech plánovaných dnů najednou (sezení se projdou jednou, ne za každý den).
    private func busy(doc: AppDocument) -> [Int: [BusyInterval]] {
        DayPlan.busyIntervals(doc, days: plan.map(\.day), excluding: Set(plan.flatMap { $0.items.compactMap { $0.carry?.id } }),
                              clock: store.clock, external: appleCalendar.busyIntervals)
    }

    @ViewBuilder
    private func scrolling(maxHeight: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        if scrolls {
            ScrollView { content() }
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content()
        }
    }

    /// Den v plánu na víc dní: nadpis s počtem bloků, časová osa a bloky.
    private func dayGroup(_ i: Int, busy: [BusyInterval], doc: AppDocument, now: Int) -> some View {
        let day = plan[i]
        let chosen = day.items.filter { $0.include && $0.isPlaced }
        let meta = chosen.isEmpty ? "nic nenavrhuji"
            : "\(chosen.count) \(Format.plural(chosen.count, "blok", "bloky", "bloků")) · \(Format.duration(chosen.reduce(0) { $0 + $1.minutes } * 60))"
        return VStack(alignment: .leading, spacing: 8) {
            ListHeading(Format.date(day.day, .weekdayDayNumericMonth, clock: store.clock), meta: meta)
            DayAxis(items: day.items, busy: busy, range: DayPlan.dayRange(doc.settings, day: day.day, clock: store.clock),
                    to: bounds(day, doc: doc).to, now: now, clock: store.clock)
            if day.items.isEmpty {
                Text("Cíl dne je splněný nebo naplánovaný, nebo se do dne nic nevejde.").font(Typo.small).foregroundStyle(Palette.text3)
            } else {
                rows(i)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dayplan.day.\(i)")
    }

    private func rows(_ i: Int) -> some View {
        let day = plan[i]
        let from = bounds(day, doc: store.document).from
        return VStack(spacing: 0) {
            ForEach($plan[i].items) { $item in
                DayPlanRow(item: $item, day: day.day, placeholder: from, clock: store.clock,
                           resize: { reflow(i, resizing: item.key, to: $0) }, remove: { reflow(i, removing: item.key) })
            }
        }
    }

    /// Cíl · odučeno · už v plánu · navrhuji (plán jednoho dne)
    private func summary(doc: AppDocument, day: DayPlan.PlannedDay) -> some View {
        let next = store.clock.addDays(day.day, 1)
        let studied = doc.alive(Session.self).filter { $0.start >= day.day && $0.start < next }.reduce(0) { $0 + $1.durationSec }
        let planned = doc.alive(PlanBlock.self)
            .filter { !$0.done && $0.start >= day.day && $0.start < next && $0.start + $0.durationMin * StudyClock.minute > day.now }
            .reduce(0) { $0 + $1.durationMin }
        return HStack(spacing: 22) {
            figure("cíl", doc.settings.dailyGoalMin * 60)
            if day.now <= store.nowMs { figure("odučeno", studied) }
            figure("už v plánu", planned * 60)
            figure("navrhuji", proposedMinutes([day]) * 60).accessibilityIdentifier("dayplan.proposed")
        }
        .font(Typo.small)
    }

    private func proposedMinutes(_ days: [DayPlan.PlannedDay]) -> Int {
        days.reduce(0) { $0 + $1.items.filter { $0.include && $0.isPlaced }.reduce(0) { $0 + $1.minutes } }
    }

    private func figure(_ label: String, _ sec: Int) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(Palette.text2)
            Text(Format.duration(sec)).fontWeight(.semibold).monospacedDigit().foregroundStyle(Palette.text)
        }
        .accessibilityElement(children: .combine)
    }

    /// „Plánuji mezi 08:00 a 22:00“ – rozmezí dne je synchronizované nastavení (`planDayStart`/`planDayEnd`).
    private func dayWindow(_ settings: Core.Settings) -> some View {
        HStack(spacing: 8) {
            Text("Plánuji mezi")
            TimeOfDayField(value: settings.planDayStart) { v in store.updateSettings { $0.planDayStart = v } }
            Text("a")
            TimeOfDayField(value: settings.planDayEnd) { v in store.updateSettings { $0.planDayEnd = v } }
            Text("· pauza podle délky bloku · náročná látka přednostně do doby, kdy se ti nejlépe soustředí")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.small)
        .foregroundStyle(Palette.text3)
    }

    // MARK: - Akce

    private func change(to next: PlanSpan) {
        guard next != span else { return }
        span = next
        extra = 0
        propose()
    }

    private func propose() {
        plan = Self.proposal(store, calendar: appleCalendar, span: span, extra: plan.count == 1 ? extra : 0)
    }

    /// Po změně délky nebo odebrání se zbytek dne rozmístí znovu (`reflow` na webu).
    private func reflow(_ i: Int, _ list: [DayPlanItem]) {
        let cleared = list.map { var item = $0; item.start = 0; return item }
        plan[i].items = DayPlan.place(store.document, items: cleared, now: plan[i].now, clock: store.clock, external: appleCalendar.busyIntervals)
    }

    private func reflow(_ i: Int, resizing key: String, to minutes: Int) {
        reflow(i, plan[i].items.map { var item = $0; if item.key == key { item.minutes = minutes }; return item })
    }

    private func reflow(_ i: Int, removing key: String) {
        reflow(i, plan[i].items.filter { $0.key != key })
    }

    private func save() {
        let doc = store.document
        let saved = plan.map { DayPlan.blocks($0.items, in: doc) }
        let blocks = saved.flatMap { $0 }
        guard !blocks.isEmpty else { return }
        store.upsert(blocks)
        let n = blocks.count, days = saved.filter { !$0.isEmpty }.count
        let added = "Do kalendáře \(Format.plural(n, "přidán", "přidány", "přidáno")) \(n) \(Format.plural(n, "blok", "bloky", "bloků"))"
        toasts.showAfterSheet(days > 1 ? "\(added) na \(days) \(Format.plural(days, "den", "dny", "dní"))" : added)
        dismiss()
    }
}

/// Jeden navržený blok: zaškrtnutí, začátek, předmět a důvody, délka, odebrání. Bez ovládacích prvků AppKitu –
/// v plánu na týden je řádků přes třicet a každý prvek AppKitu se při prvním posunu do obrazu kreslí zvlášť
/// (posun se pak seká). Čas se mění v malém okně po kliknutí, délka tlačítky −/+.
private struct DayPlanRow: View {
    @Environment(AppStore.self) private var store
    @Binding var item: DayPlanItem
    let day: Int
    /// Čas, který se ukáže u bloku, který se nevešel (začátek zbytku dne).
    let placeholder: Int
    let clock: StudyClock
    let resize: @MainActor (Int) -> Void
    let remove: @MainActor () -> Void
    @State private var editsStart = false

    var body: some View {
        let subject = SubjectInfo(item.subjectId, in: store.document)
        ListRow {
            Button { item.include.toggle() } label: { BlockCheck(item.include ? .done : .open) }
                .buttonStyle(.plain)
                .accessibilityLabel("Zařadit")
                .accessibilityValue(item.include ? "ano" : "ne")
                .accessibilityIdentifier("dayplan.include.\(item.key)")
            Button { editsStart = true } label: {
                Text(Format.time(item.isPlaced ? item.start : placeholder, clock: clock))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(item.isPlaced ? Palette.text : Palette.text3)
                    .frame(width: 52, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Změnit začátek")
            .popover(isPresented: $editsStart, arrowEdge: .bottom) {
                DatePicker("Začátek", selection: start, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .padding(12)
            }
            ColorMark(color: subject.color)
            VStack(alignment: .leading, spacing: 2) {
                (Text(subject.name).fontWeight(.medium).foregroundStyle(Palette.text) + Text("  \(item.displayTitle)").foregroundStyle(Palette.text2))
                    .lineLimit(1)
                Text(item.isPlaced ? item.reasons.joined(separator: " · ") : "nevejde se do dne")
                    .font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                step("minus", to: shorter, label: "Kratší")
                Text("\(item.minutes) min").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Palette.text2)
                    .frame(minWidth: 50)
                step("plus", to: longer, label: "Delší")
            }
            Button { remove() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.study(.ghost, size: .small))
                .help("Odebrat")
                .accessibilityLabel("Odebrat")
        }
        .opacity(item.include ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dayplan.row.\(item.key)")
    }

    private func step(_ symbol: String, to minutes: Int?, label: String) -> some View {
        Button { minutes.map(resize) } label: { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            .buttonStyle(.study(.ghost, size: .small))
            .disabled(minutes == nil)
            .help(label)
            .accessibilityLabel(label)
    }

    /// Nejbližší kratší a delší délka z nabídky (i z neobvyklé délky přesouvaného bloku).
    private var shorter: Int? { DayPlanSheet.durations.last { $0 < item.minutes } }
    private var longer: Int? { DayPlanSheet.durations.first { $0 > item.minutes } }

    /// Ruční změna začátku blok zařadí (bez nového rozmístění, jako na webu).
    private var start: Binding<Date> {
        Binding(
            get: { clock.date(item.isPlaced ? item.start : placeholder) },
            set: { date in
                let c = clock.calendar.dateComponents([.hour, .minute], from: date)
                item.start = clock.atMinutes(day, (c.hour ?? 0) * 60 + (c.minute ?? 0))
                item.include = true
            }
        )
    }
}

/// Čas `HH:MM` uložený jako text v nastavení.
private struct TimeOfDayField: View {
    @Environment(AppStore.self) private var store
    let value: String
    let set: (String) -> Void

    var body: some View {
        let clock = store.clock
        let day = clock.startOfDay(store.nowMs)
        DatePicker("Čas", selection: Binding(
            get: { clock.date(DayPlan.hm(day, value, clock: clock)) },
            set: { date in
                let c = clock.calendar.dateComponents([.hour, .minute], from: date)
                let text = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
                if text != value { set(text) }
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .fixedSize()
    }
}

/// Časová osa dne: obsazený čas, navržené bloky v barvě předmětu, „teď“ a hodiny po dvou.
private struct DayAxis: View {
    @Environment(AppStore.self) private var store
    let items: [DayPlanItem]
    let busy: [BusyInterval]
    let range: (start: Int, end: Int)
    let to: Int
    let now: Int
    let clock: StudyClock

    var body: some View {
        let hour = StudyClock.hour
        let axisStart = (([range.start] + busy.map(\.start)).min()! / hour) * hour
        let ends = [range.end, to] + items.filter(\.isPlaced).map { $0.start + $0.minutes * StudyClock.minute }
        let axisEnd = ((ends.max()! + hour - 1) / hour) * hour
        let span = Double(max(1, axisEnd - axisStart))
        let blocks = items.filter { $0.include && $0.isPlaced }.map { ($0, Palette.subject(SubjectInfo($0.subjectId, in: store.document).color)) }
        Canvas { ctx, size in
            func x(_ t: Int) -> CGFloat { CGFloat(Double(t - axisStart) / span) * size.width }
            let bar = CGRect(x: 0, y: 0, width: size.width, height: 22)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(Palette.panel2))
            for b in busy {
                let a = max(b.start, axisStart), e = min(b.end, axisEnd)
                guard e > a else { continue } // blok přes půlnoc jen po konec osy
                ctx.fill(Path(CGRect(x: x(a), y: 0, width: x(e) - x(a), height: 22)), with: .color(Palette.panel3))
            }
            for (it, color) in blocks {
                ctx.fill(Path(roundedRect: CGRect(x: x(it.start), y: 3, width: max(2, x(it.start + it.minutes * StudyClock.minute) - x(it.start)), height: 16), cornerRadius: 2),
                         with: .color(color))
            }
            if now > axisStart && now < axisEnd {
                ctx.fill(Path(CGRect(x: x(now) - 0.75, y: -3, width: 1.5, height: 28)), with: .color(Palette.text))
            }
            var t = axisStart
            var k = 0
            while t <= axisEnd {
                if k % 2 == 0 {
                    ctx.draw(Text("\(clock.hour(t))").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.text3),
                             at: CGPoint(x: min(max(x(t), 6), size.width - 6), y: 34))
                }
                t += hour
                k += 1
            }
        }
        .frame(height: 42)
        .accessibilityElement()
        .accessibilityLabel("Časová osa dne: \(blocks.count) navržených bloků")
    }
}
