import Core
import DesignSystem
import Engine
import SwiftUI

/// Jedna položka týdenní mřížky. Barvu nese jen předmět: odučené je syté, plán světlé s obrysem,
/// zmeškaný plán čárkovaně, běžící blok s výrazným obrysem, výuka šedá a události z ostatních
/// kalendářů šedě šrafované (obsazeno).
struct CalendarItemView: View {
    @Environment(\.colorScheme) private var scheme
    let item: CalendarWeekState.Item
    let height: CGFloat
    let now: Int
    /// Čas při tažení (nový začátek nebo konec) místo běžného popisku.
    let timeLabel: String?
    let dragging: Bool
    @State private var hovering = false

    private enum Kind { case plan, done, live, lecture, external }

    private var kind: Kind {
        switch item.item.source {
        case .block: .plan
        case .session: .done
        case .live: .live
        case .lecture: .lecture
        case .external: .external
        }
    }

    /// Blok plánu, který už proběhl a není hotový.
    private var missed: Bool { kind == .plan && !item.done && item.item.fullEnd <= now }

    private var color: Color { Palette.subject(item.subject.color) }
    /// Sytost výplně odučeného a hotového (na tmavém pozadí víc).
    private var strong: Double { scheme == .dark ? 0.36 : 0.26 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if kind == .plan && item.done { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)) }
                Text(kind == .lecture || kind == .external ? item.item.title : item.subject.name)
                    .fontWeight(kind == .external ? .medium : .semibold)
            }
            .foregroundStyle(missed ? Palette.text3 : kind == .external ? Palette.text2 : Palette.text)
            if height >= 34 { Text(missed ? "zmeškáno · \(item.detail)" : item.detail).foregroundStyle(missed ? Palette.text3 : Palette.text2) }
            if height >= 50 { Text(timeLabel ?? item.timeLabel).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.text3) }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { background.clipShape(shape) }
        .overlay { border(shape) }
        .shadow(color: .black.opacity(dragging ? 0.3 : 0), radius: dragging ? 10 : 0, y: 2)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .help(item.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.tooltip)
        .accessibilityAddTraits(kind == .live || kind == .external ? [] : .isButton)
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .plan:
            if dragging { Palette.panel2 } else if missed { Color.clear } else { color.opacity(item.done ? strong : hovering ? 0.18 : 0.11) }
        case .done: color.opacity(hovering ? strong + 0.06 : strong)
        case .live: color.opacity(strong)
        case .lecture: Palette.panel3
        case .external: BusyHatch()
        }
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        switch kind {
        case .plan:
            if missed {
                shape.strokeBorder(Palette.text3.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else if !item.done {
                shape.strokeBorder(color.opacity(0.6), lineWidth: 1)
            }
        case .live: shape.strokeBorder(color, lineWidth: 1.5)
        case .external: shape.strokeBorder(Palette.line)
        case .done, .lecture: EmptyView()
        }
    }
}

/// Obsazený čas z jiného kalendáře: jemné šedé šrafování – barvu v kalendáři nesou jen předměty.
struct BusyHatch: View {
    var body: some View {
        Canvas { ctx, size in
            var lines = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 8
            }
            ctx.stroke(lines, with: .color(Palette.lineStrong.opacity(0.8)), lineWidth: 3)
        }
    }
}
