import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Ranní plánování (`DayPlanModal` na webu): návrh bloků na zbytek dne, úpravy a uložení do kalendáře.
struct DayPlanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    /// Kolikrát se přidal „Další blok“ (+25 min k dennímu cíli).
    @State private var extra = 0
    @State private var items: [DayPlanItem]
    /// Bez posouvání – jen pro náhledy (ImageRenderer nevykreslí ScrollView).
    private let scrolls: Bool

    static let durations = [15, 25, 30, 45, 50, 60, 75, 90, 120]

    init(items: [DayPlanItem], scrolls: Bool = true) {
        _items = State(initialValue: items)
        self.scrolls = scrolls
    }

    var body: some View {
        let now = store.nowMs
        let clock = store.clock
        let doc = store.document
        let bounds = DayPlan.dayBounds(doc.settings, now: now, clock: clock)
        EditorSheet("Plán na dnešek · \(Format.date(now, .weekdayDayMonth, clock: clock))", width: 720) {
            summary(doc: doc, now: now, day: bounds.day)
            DayAxis(items: items, busy: DayPlan.busyIntervals(doc, day: bounds.day, excluding: carried, clock: clock),
                    range: DayPlan.dayRange(doc.settings, day: bounds.day, clock: clock), to: bounds.to, now: now, clock: clock)
            if items.isEmpty {
                Text("Na dnešek nic dalšího nenavrhuji – cíl je splněný nebo naplánovaný. Přidat můžeš tlačítkem „Další blok“.")
                    .font(Typo.small).foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if scrolls {
                ScrollView { rows(day: bounds.day, from: bounds.from) }
                    .frame(maxHeight: 360)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                rows(day: bounds.day, from: bounds.from)
            }
            dayWindow(doc.settings)
        } footer: {
            Button { propose(extra: extra) } label: { Label("Navrhnout znovu", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.denik(.ghost))
                .accessibilityIdentifier("dayplan.again")
            Spacer()
            Button("Zrušit") { dismiss() }.buttonStyle(.denik(.ghost)).keyboardShortcut(.cancelAction)
            Button {
                extra += 1
                propose(extra: extra)
            } label: { Label("Další blok", systemImage: "plus") }
                .buttonStyle(.denik(.normal))
                .accessibilityIdentifier("dayplan.more")
            Button(action: save) { Label("Uložit do kalendáře", systemImage: "calendar.badge.checkmark") }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!items.contains { $0.include && $0.isPlaced })
                .accessibilityIdentifier("dayplan.save")
        }
    }

    private var carried: Set<String> { Set(items.compactMap { $0.carry?.id }) }

    private func rows(day: Int, from: Int) -> some View {
        VStack(spacing: 0) {
            ForEach($items) { $item in
                DayPlanRow(item: $item, day: day, placeholder: from, clock: store.clock,
                           resize: { reflow(resizing: item.key, to: $0) }, remove: { reflow(removing: item.key) })
            }
        }
    }

    /// Cíl · odučeno · už v plánu · navrhuji
    private func summary(doc: AppDocument, now: Int, day: Int) -> some View {
        let next = store.clock.addDays(day, 1)
        let studied = doc.alive(Session.self).filter { $0.start >= day }.reduce(0) { $0 + $1.durationSec }
        let planned = doc.alive(PlanBlock.self)
            .filter { !$0.done && $0.start >= day && $0.start < next && $0.start + $0.durationMin * StudyClock.minute > now }
            .reduce(0) { $0 + $1.durationMin }
        let proposed = items.filter { $0.include && $0.isPlaced }.reduce(0) { $0 + $1.minutes }
        return HStack(spacing: 22) {
            figure("cíl", doc.settings.dailyGoalMin * 60)
            figure("odučeno", studied)
            figure("už v plánu", planned * 60)
            figure("navrhuji", proposed * 60).accessibilityIdentifier("dayplan.proposed")
        }
        .font(Typo.small)
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

    private func propose(extra: Int) {
        items = DayPlan.propose(store.document, now: store.nowMs, extra: extra, clock: store.clock)
    }

    /// Po změně délky nebo odebrání se zbytek rozmístí znovu (`reflow` na webu).
    private func reflow(_ list: [DayPlanItem]) {
        let cleared = list.map { var i = $0; i.start = 0; return i }
        items = DayPlan.place(store.document, items: cleared, now: store.nowMs, clock: store.clock)
    }

    private func reflow(resizing key: String, to minutes: Int) {
        reflow(items.map { var i = $0; if i.key == key { i.minutes = minutes }; return i })
    }

    private func reflow(removing key: String) {
        reflow(items.filter { $0.key != key })
    }

    private func save() {
        let blocks = DayPlan.blocks(items, in: store.document)
        guard !blocks.isEmpty else { return }
        store.upsert(blocks)
        let n = blocks.count
        toasts.showAfterSheet("Do kalendáře \(Format.plural(n, "přidán", "přidány", "přidáno")) \(n) \(Format.plural(n, "blok", "bloky", "bloků"))")
        dismiss()
    }
}

/// Jeden navržený blok: zaškrtnutí, začátek, předmět a důvody, délka, odebrání.
private struct DayPlanRow: View {
    @Environment(AppStore.self) private var store
    @Binding var item: DayPlanItem
    let day: Int
    /// Čas, který se ukáže u bloku, který se nevešel (začátek zbytku dne).
    let placeholder: Int
    let clock: StudyClock
    let resize: @MainActor (Int) -> Void
    let remove: @MainActor () -> Void

    var body: some View {
        let subject = SubjectInfo(item.subjectId, in: store.document)
        ListRow {
            Toggle("Zařadit", isOn: $item.include).labelsHidden().toggleStyle(.checkbox)
                .accessibilityIdentifier("dayplan.include.\(item.key)")
            DatePicker("Začátek", selection: start, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .opacity(item.isPlaced ? 1 : 0.45)
                .frame(width: 76)
            ColorMark(color: subject.color)
            VStack(alignment: .leading, spacing: 2) {
                (Text(subject.name).fontWeight(.medium).foregroundStyle(Palette.text) + Text("  \(item.title)").foregroundStyle(Palette.text2))
                    .lineLimit(1)
                Text(item.isPlaced ? item.reasons.joined(separator: " · ") : "nevejde se do dnešního dne")
                    .font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Délka", selection: Binding(get: { item.minutes }, set: resize)) {
                ForEach(durations, id: \.self) { Text("\($0) min").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.denik(.ghost, size: .small))
                .help("Odebrat")
                .accessibilityLabel("Odebrat")
        }
        .opacity(item.include ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dayplan.row.\(item.key)")
    }

    /// Délky v nabídce – i neobvyklá délka přesouvaného bloku.
    private var durations: [Int] {
        DayPlanSheet.durations.contains(item.minutes) ? DayPlanSheet.durations : (DayPlanSheet.durations + [item.minutes]).sorted()
    }

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
