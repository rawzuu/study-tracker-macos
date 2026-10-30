import Core
import DesignSystem
import Engine
import Focus
import SwiftUI

/// Rozměry a kroky týdenní mřížky (`PlannerPage` na webu).
enum WeekMetrics {
    static let hourHeight: CGFloat = 48
    static let gutter: CGFloat = 52
    static let lastHour = 24
    static let visibleHeight: CGFloat = 640
    /// Nejmenší výška položky (krátké sezení musí jít trefit myší).
    static let minItemHeight: CGFloat = 20
}

/// Tažení bloku plánu: posun o dny a minuty, nebo změna délky – stejné kroky jako na webu.
struct BlockDrag: Equatable {
    let blockId: String
    var dayDelta = 0
    var minDelta = 0
    /// Změna délky (min); `nil` = blok se přesouvá.
    var durDelta: Int?

    /// Přesun: o celé dny podle šířky sloupce, v čase po 15 minutách.
    static func move(_ blockId: String, translation: CGSize, columnWidth: CGFloat) -> BlockDrag {
        let minutes = Double(translation.height / WeekMetrics.hourHeight) * 60
        return BlockDrag(blockId: blockId, dayDelta: Int(JS.round(Double(translation.width / columnWidth))), minDelta: Int(JS.round(minutes / 15)) * 15)
    }

    /// Délka tažením za spodní okraj: po 5 minutách, aspoň 10 min, nejvýš 12 h.
    static func resize(_ blockId: String, translation: CGFloat, durationMin: Int) -> BlockDrag {
        let want = Int(JS.round(Double(translation / WeekMetrics.hourHeight) * 60 / 5)) * 5
        return BlockDrag(blockId: blockId, durDelta: max(10 - durationMin, min(12 * 60 - durationMin, want)))
    }

    var isNoOp: Bool { durDelta.map { $0 == 0 } ?? (dayDelta == 0 && minDelta == 0) }

    /// Začátek přesunutého bloku (přes změnu času drží místní čas jako na webu).
    func movedStart(_ start: Int, clock: StudyClock) -> Int {
        clock.addDays(start, dayDelta) + minDelta * StudyClock.minute
    }

    /// Klik do prázdna: začátek po půlhodinách (`onGridClick` na webu).
    static func slotStart(y: CGFloat, day: Int, firstHour: Int, clock: StudyClock) -> Int {
        let minutes = Int((Double(y / WeekMetrics.hourHeight) * 60 / 30).rounded(.down)) * 30 + firstHour * 60
        return clock.atMinutes(day, minutes)
    }
}

/// Co se s položkami mřížky dá dělat – rozhoduje stránka Kalendář.
struct WeekGridActions {
    var emptySlot: (Int) -> Void
    var open: (CalendarItem) -> Void
    var exam: (String) -> Void
    var move: (_ blockId: String, BlockDrag) -> Void
}

/// Týdenní mřížka: hodiny × dny, položky v barvách předmětů, přetahování bloků plánu.
struct WeekGrid: View {
    let state: CalendarWeekState
    let now: Int
    let clock: StudyClock
    let actions: WeekGridActions
    /// `false` = celá výška bez posouvání (náhledy – ImageRenderer nevykreslí ScrollView).
    var scrolls = true
    /// Kdy blokuje Soustředění (pruh u pravého okraje dne).
    var focus: [FocusEngine.Interval] = []
    @State private var drag: BlockDrag?
    @State private var columnWidth: CGFloat = 100

    private var gridHeight: CGFloat { CGFloat(WeekMetrics.lastHour - state.firstHour) * WeekMetrics.hourHeight }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: WeekMetrics.gutter, height: 1)
                ForEach(state.days) { day in
                    DayHeader(day: day, openExam: actions.exam).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 8)
            Rectangle().fill(Palette.line).frame(height: 1)
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { grid }
                        .frame(height: min(gridHeight, WeekMetrics.visibleHeight))
                        .onAppear {
                            // Na aktuální hodinu – tři hodiny nad ní jsou vidět.
                            let hour = clock.calendar.component(.hour, from: clock.date(now))
                            proxy.scrollTo(max(state.firstHour, min(WeekMetrics.lastHour - 1, hour - 3)), anchor: .top)
                        }
                }
            } else {
                grid
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.week")
    }
}

extension WeekGrid {
    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            HourLabels(first: state.firstHour).frame(width: WeekMetrics.gutter, height: gridHeight)
            ForEach(state.days) { day in
                DayColumn(day: day, firstHour: state.firstHour, now: now, clock: clock, columnWidth: columnWidth, drag: $drag, actions: actions,
                          focus: focus.filter { $0.end > day.start && $0.start < clock.addDays(day.start, 1) })
                    .frame(maxWidth: .infinity)
                    .frame(height: gridHeight)
                    // Tažený blok se kreslí nad sousedními dny.
                    .zIndex(day.items.contains { $0.item.blockId != nil && $0.item.blockId == drag?.blockId } ? 1 : 0)
            }
        }
        .background(alignment: .top) {
            // Kotvy pro posun na aktuální hodinu
            VStack(spacing: 0) {
                ForEach(state.firstHour..<WeekMetrics.lastHour, id: \.self) { h in
                    Color.clear.frame(height: WeekMetrics.hourHeight).id(h)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            columnWidth = max(1, (width - WeekMetrics.gutter) / 7)
        }
    }
}

extension CalendarItem {
    /// Id bloku plánu, pokud položka je blok.
    var blockId: String? {
        if case .block(let id) = source { id } else { nil }
    }
}

// MARK: - Záhlaví a hodiny

private struct DayHeader: View {
    let day: CalendarWeekState.Day
    let openExam: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(day.weekday.lowercased()).font(.system(size: 12, weight: day.isToday ? .semibold : .regular))
                    .foregroundStyle(day.isToday ? Palette.danger : Palette.text2)
                Text("\(day.number)")
                    .font(.system(size: 16, weight: day.isToday ? .semibold : .medium)).monospacedDigit()
                    .foregroundStyle(day.isToday ? .white : Palette.text)
                    .padding(.horizontal, day.isToday ? 7 : 0)
                    .frame(minWidth: day.isToday ? 26 : nil, minHeight: 24)
                    .background(day.isToday ? Palette.danger : .clear, in: Capsule())
            }
            Text(day.total ?? "–").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(day.total == nil ? Palette.text3 : day.isToday ? Palette.text : Palette.text2)
            SubjectMix(times: day.mix).frame(height: 3).frame(maxWidth: .infinity).padding(.trailing, 10).padding(.top, 2)
            ForEach(day.exams) { e in
                Button { openExam(e.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Palette.danger)
                        Text(e.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(Palette.subject(e.subject.color).opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(e.name)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Barevný proužek: odučeno po předmětech poměrně k času.
struct SubjectMix: View {
    let times: [SubjectTime]

    var body: some View {
        Canvas { ctx, size in
            let total = times.reduce(0) { $0 + $1.sec }
            guard total > 0 else { return }
            let gaps = CGFloat(times.count - 1)
            var x: CGFloat = 0
            for t in times {
                let w = (size.width - gaps) * CGFloat(t.sec) / CGFloat(total)
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Palette.subject(t.subject.color)))
                x += w + 1
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct HourLabels: View {
    let first: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(first..<WeekMetrics.lastHour, id: \.self) { h in
                Text("\(h):00")
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.text3)
                    // Popisek na lince hodiny; první je pod horním okrajem.
                    .offset(y: h == first ? 0 : CGFloat(h - first) * WeekMetrics.hourHeight - 7)
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .accessibilityHidden(true)
    }
}

// MARK: - Den

private struct DayColumn: View {
    let day: CalendarWeekState.Day
    let firstHour: Int
    let now: Int
    let clock: StudyClock
    let columnWidth: CGFloat
    @Binding var drag: BlockDrag?
    let actions: WeekGridActions
    var focus: [FocusEngine.Interval] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                for i in 1..<(WeekMetrics.lastHour - firstHour) {
                    let y = CGFloat(i) * WeekMetrics.hourHeight
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Palette.line.opacity(0.8)))
                }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 1, height: size.height)), with: .color(Palette.line))
                for band in focusBands(height: size.height) {
                    ctx.fill(Path(roundedRect: CGRect(x: size.width - 4, y: band.lowerBound, width: 3, height: band.upperBound - band.lowerBound),
                                  cornerRadius: 1.5), with: .color(Palette.focus))
                }
            }
            .background(day.isToday ? Palette.panel : .clear)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                actions.emptySlot(BlockDrag.slotStart(y: p.y, day: day.start, firstHour: firstHour, clock: clock))
            }
            .accessibilityHidden(true)

            ItemsLayout {
                ForEach(day.items) { item in
                    itemView(item).layoutValue(key: ItemSlot.self, value: slot(item))
                }
            }

            if day.isToday {
                let y = CGFloat(clock.minutesOfDay(now) / 60 - Double(firstHour)) * WeekMetrics.hourHeight
                NowLine().offset(y: y).allowsHitTesting(false)
            }
        }
    }

    /// Svislé úseky (y) blokování Soustředění v tomto dni.
    private func focusBands(height: CGFloat) -> [ClosedRange<CGFloat>] {
        let dayEnd = clock.addDays(day.start, 1)
        return focus.map { band in
            let top = band.start <= day.start ? 0 : CGFloat(clock.minutesOfDay(band.start) - Double(firstHour * 60)) / 60 * WeekMetrics.hourHeight
            let bottom = band.end >= dayEnd ? height : CGFloat(clock.minutesOfDay(band.end) - Double(firstHour * 60)) / 60 * WeekMetrics.hourHeight
            return max(0, top)...max(max(0, top), min(height, bottom))
        }
    }

    private func slot(_ item: CalendarWeekState.Item) -> ItemSlot.Value {
        let it = item.item
        let top = CGFloat(clock.minutesOfDay(it.start) - Double(firstHour * 60)) / 60 * WeekMetrics.hourHeight
        return .init(top: top, height: height(item), lane: item.lane.lane, lanes: item.lane.lanes)
    }

    /// Výška položky; při změně délky tažením roste jen poslední kus bloku (u bloku přes půlnoc ten ranní).
    private func height(_ item: CalendarWeekState.Item) -> CGFloat {
        let it = item.item
        let grow = it.blockId != nil && it.blockId == drag?.blockId && it.isLastPart ? drag?.durDelta ?? 0 : 0
        let minutes = max(1, Double(it.end - it.start) / Double(StudyClock.minute)) + Double(grow)
        return max(WeekMetrics.minItemHeight, CGFloat(minutes / 60) * WeekMetrics.hourHeight - 2)
    }

    @ViewBuilder
    private func itemView(_ item: CalendarWeekState.Item) -> some View {
        let h = height(item)
        if let blockId = item.item.blockId {
            let dragging = drag?.blockId == blockId
            CalendarItemView(item: item, height: h, now: now, timeLabel: dragging ? dragLabel(item) : nil, dragging: dragging)
                .pointerStyle(dragging ? .grabActive : .grabIdle)
                .gesture(moveGesture(item, blockId: blockId))
                .overlay(alignment: .bottom) {
                    if item.item.isLastPart { ResizeHandle(color: item.subject.color).gesture(resizeGesture(item, blockId: blockId)) }
                }
                .offset(x: dragging ? CGFloat(drag?.dayDelta ?? 0) * columnWidth : 0,
                        y: dragging ? CGFloat(drag?.minDelta ?? 0) / 60 * WeekMetrics.hourHeight : 0)
                .accessibilityAction { actions.open(item.item) }
                .accessibilityIdentifier("cal.block.\(blockId)")
        } else {
            CalendarItemView(item: item, height: h, now: now, timeLabel: nil, dragging: false)
                .onTapGesture { actions.open(item.item) }
                .accessibilityAction { actions.open(item.item) }
                .accessibilityIdentifier(identifier(item.item))
        }
    }

    private func identifier(_ it: CalendarItem) -> String {
        switch it.source {
        case .block(let id): "cal.block.\(id)"
        case .session(let id): "cal.session.\(id)"
        case .live: "cal.live"
        case .lecture(_, let key): "cal.lecture.\(key)"
        case .external(let id): "cal.external.\(id)"
        }
    }

    /// Čas, který blok bude mít po puštění (přesun) nebo nový konec (změna délky).
    private func dragLabel(_ item: CalendarWeekState.Item) -> String? {
        guard let drag else { return nil }
        let start = item.item.fullStart
        if let dur = drag.durDelta {
            let minutes = Int((Double(item.item.fullEnd - start) / Double(StudyClock.minute)).rounded()) + dur
            return "\(Format.time(start, clock: clock))–\(Format.time(start + minutes * StudyClock.minute, clock: clock))"
        }
        return Format.time(drag.movedStart(start, clock: clock), clock: clock)
    }

    /// Překreslí mřížku, jen když se tažení posunulo o celý krok (15 min, den, 5 min délky) –
    /// pohyb myši mezi kroky nic nepřekresluje.
    private func update(_ next: BlockDrag) {
        if drag != next { drag = next }
    }

    /// Klik otevře blok, tažení (od 4 bodů) ho přesouvá – jako `onPlanDown` na webu.
    ///
    /// Posun se měří v souřadnicích okna, ne bloku: tažený blok se sám posouvá (`offset`), a v jeho
    /// vlastních souřadnicích by každý posun změnil i naměřené tažení – blok by poskakoval tam a zpět.
    private func moveGesture(_ item: CalendarWeekState.Item, blockId: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                guard drag != nil || hypot(v.translation.width, v.translation.height) >= 4 else { return }
                update(.move(blockId, translation: v.translation, columnWidth: columnWidth))
            }
            .onEnded { _ in
                let done = drag
                drag = nil
                if let done, done.blockId == blockId {
                    if !done.isNoOp { actions.move(blockId, done) }
                } else {
                    actions.open(item.item)
                }
            }
    }

    /// Úchyt se posouvá se spodním okrajem bloku – i tady se měří v souřadnicích okna.
    private func resizeGesture(_ item: CalendarWeekState.Item, blockId: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                guard drag != nil || abs(v.translation.height) >= 3 else { return }
                let minutes = Int((Double(item.item.fullEnd - item.item.fullStart) / Double(StudyClock.minute)).rounded())
                update(.resize(blockId, translation: v.translation.height, durationMin: minutes))
            }
            .onEnded { _ in
                let done = drag
                drag = nil
                if let done, done.blockId == blockId {
                    if !done.isNoOp { actions.move(blockId, done) }
                } else {
                    actions.open(item.item)
                }
            }
    }
}

/// Spodní okraj bloku plánu: tažením se mění délka (úchyt se ukáže při najetí myší).
private struct ResizeHandle: View {
    let color: String
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Capsule().fill(Palette.subject(color)).frame(width: 18, height: 2).padding(.bottom, 2).opacity(hovering ? 0.8 : 0)
            }
            .onHover { hovering = $0 }
            .pointerStyle(.rowResize)
            .accessibilityHidden(true)
    }
}

private struct NowLine: View {
    var body: some View {
        Rectangle().fill(Palette.danger).frame(height: 2)
            .overlay(alignment: .leading) { Circle().fill(Palette.danger).frame(width: 9, height: 9).offset(x: -4.5) }
            .accessibilityHidden(true)
    }
}

// MARK: - Rozložení položek dne

/// Kde položka ve dni je: svisle podle času, vodorovně podle sloupce mezi překrývajícími se položkami.
private struct ItemSlot: LayoutValueKey {
    struct Value: Equatable {
        var top: CGFloat
        var height: CGFloat
        var lane: Int
        var lanes: Int
    }

    static let defaultValue = Value(top: 0, height: 0, lane: 0, lanes: 1)
}

private struct ItemsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let slot = view[ItemSlot.self]
            let laneWidth = bounds.width / CGFloat(max(1, slot.lanes))
            view.place(
                at: CGPoint(x: bounds.minX + laneWidth * CGFloat(slot.lane) + 2, y: bounds.minY + slot.top),
                proposal: ProposedViewSize(width: max(0, laneWidth - 4), height: slot.height)
            )
        }
    }
}
