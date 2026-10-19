import SwiftUI

/// Písmo: všude systémové (SF Pro), čísla s pevnou šířkou číslic. Hierarchii dělá velikost a řez,
/// ne jiné písmo.
public enum Typo {
    public static let pageTitle = Font.system(size: 28, weight: .bold)
    public static let sectionTitle = Font.system(size: 15, weight: .semibold)
    /// Nadpis skupiny v seznamu („Dopoledne“) – v barvě akcentu.
    public static let heading = Font.system(size: 14, weight: .bold)
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    public static let body = Font.system(size: 13.5)
    public static let small = Font.system(size: 12)
}

/// Ikony stránek – stejné v postranním panelu i v hlavičce stránky. Každá stránka má svou barvu.
public enum PageGlyph: Sendable {
    case today(day: Int)
    case calendar, timer, history, subjects, settings
    /// Ostatní stránky (přehledy) – šedý symbol.
    case symbol(String)

    public var color: Color {
        switch self {
        case .today: Palette.accent
        case .calendar: Palette.danger
        case .timer: Palette.breakColor
        case .history: Palette.success
        case .subjects: Palette.focus
        case .settings, .symbol: Palette.text2
        }
    }
}

/// Ikona stránky; `today` je kalendářový list s dnešním dnem.
public struct PageGlyphView: View {
    let glyph: PageGlyph
    let size: CGFloat

    public init(_ glyph: PageGlyph, size: CGFloat = 16) {
        self.glyph = glyph
        self.size = size
    }

    public var body: some View {
        Group {
            switch glyph {
            case .today(let day):
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Palette.accent)
                    UnevenRoundedRectangle(topLeadingRadius: size * 0.2, topTrailingRadius: size * 0.2, style: .continuous)
                        .fill(.black.opacity(0.18)).frame(height: size * 0.27)
                    Text("\(day)").font(.system(size: size * 0.46, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white).frame(maxHeight: .infinity).padding(.top, size * 0.22)
                }
                .frame(width: size * 0.86, height: size * 0.82)
            case .calendar: symbol("calendar")
            case .timer: symbol("stopwatch")
            case .history: symbol("checkmark.square")
            case .subjects: symbol("books.vertical")
            case .settings: symbol("gearshape")
            case .symbol(let name): symbol(name)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: size * 0.86, weight: .medium)).foregroundStyle(glyph.color)
    }
}

/// Hlavička stránky: ikona, velký nadpis a pod ním jeden řádek souvislostí; akce vpravo.
public struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let glyph: PageGlyph?
    let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, glyph: PageGlyph? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if let glyph { PageGlyphView(glyph, size: 26) }
                    Text(title)
                        .font(Typo.pageTitle)
                        .kerning(-0.3)
                        .foregroundStyle(Palette.text)
                        .accessibilityIdentifier("page.title")
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    Text(subtitle).font(Typo.body).foregroundStyle(Palette.text2)
                        .padding(.leading, glyph == nil ? 0 : 38)
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) { trailing }.padding(.top, 2)
        }
    }
}

/// Sekce: nadpis, tenká linka a obsah pod ní.
public struct PageSection<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    public init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typo.sectionTitle).foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory.font(Typo.small).foregroundStyle(Palette.text3)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Nadpis skupiny v seznamu („Dopoledne“): akcentem, vpravo souhrn, pod ním linka.
public struct ListHeading<Leading: View>: View {
    let title: String
    let meta: String?
    let leading: Leading

    public init(_ title: String, meta: String? = nil, @ViewBuilder leading: () -> Leading = { EmptyView() }) {
        self.title = title
        self.meta = meta
        self.leading = leading()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            leading.foregroundStyle(Palette.accent)
            Text(title).font(Typo.heading).foregroundStyle(Palette.accent).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if let meta { Text(meta).font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3) }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .padding(.bottom, 4)
    }
}

/// Řádek seznamu (volitelně s tenkou linkou pod sebou – v tabulkách).
public struct ListRow<Content: View>: View {
    let showsDivider: Bool
    let content: Content

    public init(divider: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsDivider = divider
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) { content }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                if showsDivider { Rectangle().fill(Palette.line).frame(height: 1) }
            }
    }
}

/// Pole formuláře s popiskem nad sebou a nápovědou pod sebou (`<Field>` na webu).
public struct FormField<Content: View>: View {
    let label: String
    let hint: String?
    let content: Content

    public init(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).foregroundStyle(Palette.text2)
            content
            if let hint { Text(hint).font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Malý štítek: šedá kapsle, barevný text jen u stavu.
public struct Chip: View {
    public enum Tone { case neutral, accent, ok, warn, bad }
    let text: String
    let systemImage: String?
    let tone: Tone

    public init(_ text: String, systemImage: String? = nil, tone: Tone = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .neutral: Palette.text2
        case .accent: Palette.accent
        case .ok: Palette.success
        case .warn: Palette.warn
        case .bad: Palette.danger
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(tone == .accent ? Palette.accentSoft : Palette.panel2, in: Capsule())
    }
}

/// Barevná tečka a název předmětu (v textu a tabulkách).
public struct SubjectTag: View {
    let name: String
    let color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.subject(color)).frame(width: 7, height: 7)
            Text(name).lineLimit(1)
        }
    }
}

/// Předmět jako štítek u položky seznamu (šedá kapsle s barevnou tečkou).
public struct SubjectCapsule: View {
    let name: String
    let color: String
    var dimmed = false

    public init(name: String, color: String, dimmed: Bool = false) {
        self.name = name
        self.color = color
        self.dimmed = dimmed
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.subject(color)).frame(width: 6, height: 6).opacity(dimmed ? 0.6 : 1)
            Text(name).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(dimmed ? Palette.text3 : Palette.text2)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Palette.panel2, in: Capsule())
    }
}

/// Koláček splnění (týdenní cíl předmětu): obrys a výseč v barvě předmětu.
public struct ProgressPie: View {
    let fraction: Double
    let color: Color
    let size: CGFloat

    public init(_ fraction: Double, color: Color, size: CGFloat = 14) {
        self.fraction = fraction
        self.color = color
        self.size = size
    }

    public var body: some View {
        Canvas { ctx, s in
            let r = s.width / 2
            let c = CGPoint(x: r, y: r)
            let line = max(1.25, s.width / 10)
            ctx.stroke(Path(ellipseIn: CGRect(origin: .zero, size: s).insetBy(dx: line / 2, dy: line / 2)), with: .color(color), lineWidth: line)
            let f = min(1, max(0, fraction))
            guard f > 0 else { return }
            var wedge = Path()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: r - line * 1.6, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(color))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded())) %")
    }
}

/// Zaškrtávací políčko bloku v seznamu: hotový, běží (výseč postupu), čeká, zmeškaný, navržený.
public struct BlockCheck: View {
    public enum State: Equatable, Sendable {
        case open, done, missed, suggested
        case running(Double)
    }

    let state: State
    let color: Color

    public init(_ state: State, color: Color = Palette.accent) {
        self.state = state
        self.color = color
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        ZStack {
            switch state {
            case .done:
                shape.fill(color)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            case .running(let f):
                shape.strokeBorder(color, lineWidth: 1.5)
                ProgressPie(f, color: color, size: 9).opacity(1)
            case .open:
                shape.strokeBorder(Palette.lineStrong, lineWidth: 1.5)
            case .missed:
                shape.strokeBorder(Palette.lineStrong, lineWidth: 1.5)
                Rectangle().fill(Palette.text3).frame(width: 7, height: 1.5)
            case .suggested:
                shape.strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Tenký ukazatel průběhu. Nad 100 % zůstane plný.
public struct ProgressLine: View {
    let value: Double
    let color: Color

    public init(_ value: Double, color: Color) {
        self.value = value
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.panel2)
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) %")
    }
}

/// Prázdný stav sekce.
public struct EmptyNote<Footer: View>: View {
    let systemImage: String
    let title: String
    let footer: Footer

    public init(_ title: String, systemImage: String, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 18)).foregroundStyle(Palette.text3)
            Text(title).foregroundStyle(Palette.text2)
            footer.font(Typo.small).foregroundStyle(Palette.text3)
        }
        .font(.system(size: 13))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

/// Upozornění: ikona, věta a akce na jemné ploše.
public struct Banner<Actions: View>: View {
    let systemImage: String
    let text: String
    let tone: Chip.Tone
    let actions: Actions

    public init(_ text: String, systemImage: String, tone: Chip.Tone = .neutral, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tone == .bad ? Palette.danger : tone == .warn ? Palette.warn : tone == .accent ? Palette.accent : Palette.text2)
            Text(text).font(Typo.body).foregroundStyle(Palette.text).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Délka „1 h 19 min“: čísla větší a tučnější, jednotky menší a šedé.
public struct DurationText: View {
    let text: String
    let size: CGFloat

    public init(_ text: String, size: CGFloat) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        Text(attributed).accessibilityLabel(text)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (i, part) in text.split(separator: " ").enumerated() {
            let isNumber = part.first?.isNumber == true
            var piece = AttributedString((i > 0 ? " " : "") + part)
            piece.font = isNumber ? Typo.number(size) : .system(size: max(11, size * 0.55), weight: .medium)
            piece.foregroundColor = isNumber ? Palette.text : Palette.text2
            out += piece
        }
        return out
    }
}

extension View {
    /// Pozadí stránky.
    public func pageBackground() -> some View {
        background(Palette.bg)
    }
}

/// Víceřádkové textové pole s nápovědou, dokud je prázdné.
public struct TextArea: View {
    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat

    public init(_ placeholder: String = "", text: Binding<String>, minHeight: CGFloat = 64) {
        self.placeholder = placeholder
        self._text = text
        self.minHeight = minHeight
    }

    public var body: some View {
        TextEditor(text: $text)
            .font(Typo.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).foregroundStyle(Palette.text3).padding(11).allowsHitTesting(false)
                }
            }
    }
}

/// Okno formuláře: nadpis, obsah a řada tlačítek dole.
public struct EditorSheet<Content: View, Footer: View>: View {
    let title: String
    let width: CGFloat
    let content: Content
    let footer: Footer

    public init(_ title: String, width: CGFloat = 480, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.width = width
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content
            HStack(spacing: 8) { footer }.padding(.top, 6)
        }
        .padding(24)
        .frame(width: width)
    }
}

/// Celé číslo s políčkem a šipkami (minuty, délka bloku). Hodnota mimo rozsah se vrátí na okraj.
public struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    public init(value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
        self._value = value
        self.range = range
        self.step = step
    }

    public var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .labelsHidden()
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
        .onChange(of: value) { _, v in
            let clamped = min(range.upperBound, max(range.lowerBound, v))
            if clamped != v { value = clamped }
        }
    }
}
