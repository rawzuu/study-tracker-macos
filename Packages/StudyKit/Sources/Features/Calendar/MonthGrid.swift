import DesignSystem
import Engine
import SwiftUI

/// Měsíční přehled (`MonthView` na webu): odučeno po předmětech, plán a zkoušky. Klik na den otevře jeho týden.
struct MonthGrid: View {
    let state: CalendarMonthState
    let openDay: (Int) -> Void

    var body: some View {
        // Grid (ne LazyVGrid): buňky jednoho týdne mají stejnou výšku, takže linky navazují.
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Format.weekdaysShort, id: \.self) { w in
                    Text(w.uppercased())
                        .font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Palette.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                }
            }
            ForEach(0..<state.cells.count / 7, id: \.self) { week in
                GridRow {
                    ForEach(state.cells[week * 7..<week * 7 + 7]) { cell in
                        MonthCell(cell: cell) { openDay(cell.day) }
                    }
                }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.month")
    }
}

private struct MonthCell: View {
    let cell: CalendarMonthState.Cell
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(cell.number)")
                        .font(.system(size: 13)).monospacedDigit()
                        .foregroundStyle(cell.isToday ? Palette.bg : Palette.text)
                        .padding(.horizontal, cell.isToday ? 5 : 0)
                        .background(cell.isToday ? Palette.text : .clear, in: RoundedRectangle(cornerRadius: 4))
                    Spacer(minLength: 4)
                    if let total = cell.total {
                        Text(total).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                }
                if cell.total != nil {
                    GeometryReader { geo in
                        SubjectMix(times: cell.subjects).frame(width: geo.size.width * cell.mixWidth)
                    }
                    .frame(height: 4)
                }
                ForEach(cell.exams) { e in
                    Text(e.name)
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.panel2, in: UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3))
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.subject(e.subject.color)).frame(width: 2) }
                }
                ForEach(cell.subjects.prefix(3)) { t in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Palette.subject(t.subject.color)).frame(width: 7, height: 7)
                        Text(t.subject.name).lineLimit(1)
                        Text(Format.duration(t.sec)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.text2)
                }
                ForEach(cell.plans) { p in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .strokeBorder(Palette.subject(p.subject.color), style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5]))
                            .frame(width: 7, height: 7)
                        Text(p.time).font(.system(size: 10.5)).monospacedDigit()
                        Text(p.subject.name).lineLimit(1)
                        if p.done { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.text3)
                    .opacity(p.done ? 0.6 : 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
            .background(hovering ? Palette.panel2 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(cell.inMonth ? 1 : 0.35)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar.month.\(cell.number)")
    }
}
