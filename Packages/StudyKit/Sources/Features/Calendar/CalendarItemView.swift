import Core
import DesignSystem
import Engine
import SwiftUI

/// Jedna položka týdenní mřížky (`.cal-item` na webu). Barvu nese jen předmět: odučené sezení je
/// plné, plán je obrys, výuka z rozvrhu je šedá.
struct CalendarItemView: View {
    @Environment(\.colorScheme) private var scheme
    let item: CalendarWeekState.Item
    let height: CGFloat
    /// Čas při tažení (nový začátek nebo konec) místo běžného popisku.
    let timeLabel: String?
    let dragging: Bool
    @State private var hovering = false

    private enum Kind { case plan, done, live, lecture }

    private var kind: Kind {
        switch item.item.source {
        case .block: .plan
        case .session: .done
        case .live: .live
        case .lecture: .lecture
        }
    }

    private var color: Color { Palette.subject(item.subject.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if kind == .plan && item.done { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)) }
                Text(kind == .lecture ? item.item.title : item.subject.name).fontWeight(kind == .lecture ? .medium : .semibold)
            }
            .foregroundStyle(titleColor)
            if height >= 34 { Text(item.detail).foregroundStyle(detailColor) }
            if height >= 50 { Text(timeLabel ?? item.timeLabel).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(timeColor) }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { background }
        .overlay { border }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(kind == .plan && item.done && !dragging ? 0.6 : 1)
        .shadow(color: .black.opacity(dragging ? 0.35 : kind == .done ? 0.25 : 0), radius: dragging ? 10 : 0, y: 1)
        .brightness(kind == .done && hovering ? 0.05 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .help(item.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.tooltip)
        .accessibilityAddTraits(kind == .live ? [] : .isButton)
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .plan: dragging ? Palette.panel2 : color.opacity(hovering ? 0.14 : 0.07)
        case .done: color
        case .live: LiveStripes(color: item.subject.color)
        case .lecture: Palette.panel3
        }
    }

    @ViewBuilder private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        switch kind {
        case .plan:
            if item.done {
                shape.strokeBorder(color.opacity(0.35), lineWidth: 1.5)
            } else {
                shape.strokeBorder(color.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        case .done, .live:
            shape.strokeBorder(Palette.subject(item.subject.color, mixedWith: 0x000000, amount: 0.3))
        case .lecture:
            shape.strokeBorder(hovering ? Palette.text3 : Palette.lineStrong)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.text3).frame(width: 2) }
        }
    }

    private var titleColor: Color {
        switch kind {
        // Na světlém pozadí je barva předmětu na text moc světlá – ztmaví se textem (jako na webu).
        case .plan: scheme == .light ? Palette.subject(item.subject.color, mixedWith: Palette.lightText, amount: 0.5) : color
        case .done, .live: Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255)
        case .lecture: Palette.text
        }
    }

    private var detailColor: Color {
        switch kind {
        case .plan, .lecture: Palette.text2
        case .done, .live: .black.opacity(0.66)
        }
    }

    private var timeColor: Color {
        switch kind {
        case .plan, .lecture: Palette.text3
        case .done, .live: .black.opacity(0.55)
        }
    }
}

/// Běžící blok: šikmé pruhy v barvě předmětu. Na webu se pruhy pohybují; tady stojí,
/// aby kalendář s běžícím blokem nepřekresloval okno 60× za sekundu.
private struct LiveStripes: View {
    let color: String

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.subject(color)))
            let light = Palette.subject(color, mixedWith: 0xFFFFFF, amount: 0.18)
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + 6, y: size.height))
                p.addLine(to: CGPoint(x: x + 6 + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.closeSubpath()
                ctx.fill(p, with: .color(light))
                x += 12
            }
        }
    }
}
