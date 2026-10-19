import DesignSystem
import SwiftUI
import WidgetData
import WidgetKit

// Vzhled widgetů „Seznam“ jako v aplikaci: systémové písmo, modrý akcent pro akce a „teď“,
// jinak barvu nesou jen předměty.
// Barvy se počítají pro vzhled, který widget právě má (světlý/tmavý), a v tlumeném režimu plochy
// (vibrant) se místo barev pracuje s průhledností.

/// Barvy widgetu pro aktuální vzhled.
struct WidgetTheme {
    let scheme: ColorScheme
    let fullColor: Bool

    init(_ scheme: ColorScheme, _ mode: WidgetRenderingMode) {
        self.scheme = scheme
        fullColor = mode == .fullColor
    }

    var bg: Color { Palette.fixed(Palette.bg, scheme) }
    var panel: Color { Palette.fixed(Palette.panel2, scheme) }
    var line: Color { Palette.fixed(Palette.lineStrong, scheme) }
    var track: Color { fullColor ? Palette.fixed(Palette.panel2, scheme) : .primary.opacity(0.18) }
    var accentSoft: Color { fullColor ? Palette.fixed(Palette.accentSoft, scheme) : .primary.opacity(0.12) }
    var danger: Color { fullColor ? Palette.fixed(Palette.danger, scheme) : .primary }
    var text: Color { fullColor ? Palette.fixed(Palette.text, scheme) : .primary }
    var text2: Color { fullColor ? Palette.fixed(Palette.text2, scheme) : .primary.opacity(0.75) }
    var text3: Color { fullColor ? Palette.fixed(Palette.text3, scheme) : .primary.opacity(0.55) }
    var accent: Color { fullColor ? Palette.fixed(Palette.accent, scheme) : .primary }
    var accentInk: Color { Palette.fixed(Palette.accentInk, scheme) }
    var rest: Color { fullColor ? Palette.fixed(Palette.breakColor, scheme) : .primary }
    var warn: Color { fullColor ? Palette.fixed(Palette.warn, scheme) : .primary }

    func subject(_ hex: String) -> Color { fullColor ? Palette.subject(hex) : .primary.opacity(0.8) }
}

/// Barvy a režim vykreslení z prostředí widgetu.
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    let content: (WidgetTheme) -> Content

    init(@ViewBuilder _ content: @escaping (WidgetTheme) -> Content) {
        self.content = content
    }

    var body: some View { content(WidgetTheme(scheme, mode)) }
}

// MARK: - Tlačítka

/// Jak se kreslí tlačítko ve widgetu: rozšíření widgetů z něj udělá `Button(intent:)`,
/// náhledy jen popisek.
public struct WidgetActions: Sendable {
    public let make: @MainActor @Sendable (WidgetCommand, AnyView) -> AnyView

    public init(_ make: @escaping @MainActor @Sendable (WidgetCommand, AnyView) -> AnyView) {
        self.make = make
    }

    public static let preview = WidgetActions { _, label in label }
}

extension EnvironmentValues {
    @Entry public var widgetActions: WidgetActions = .preview
}

/// Hlavní tlačítko widgetu: široké a barevné. Popisek se nikdy neusekne – když se nevejde, použije
/// se kratší varianta a nakonec jen ikona (úzký widget, větší písmo v systému).
struct PrimaryButton: View {
    enum Tint { case accent, rest }

    @Environment(\.widgetActions) private var actions
    let command: WidgetCommand
    let title: String
    var short: String?
    let symbol: String
    var tint = Tint.accent

    var body: some View {
        Themed { t in
            actions.make(command, AnyView(
                content
                    .foregroundStyle(t.fullColor ? t.accentInk : t.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(fill(t), in: Capsule())
                    .widgetAccentable()
                    .contentShape(Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
            ))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let short {
            ViewThatFits(in: .horizontal) {
                label(title)
                label(short)
                icon.padding(.horizontal, 8)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                label(title)
                icon.padding(.horizontal, 8)
            }
        }
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 5) {
            icon
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10)
    }

    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .bold))
    }

    /// V tlumeném režimu plochy (bez barev) nese tlačítko jen jemný podklad – text zůstane čitelný.
    private func fill(_ t: WidgetTheme) -> Color {
        guard t.fullColor else { return .primary.opacity(0.16) }
        return tint == .rest ? t.rest : t.accent
    }
}

/// Vedlejší tlačítko: kruh s ikonou (hotovo, konec) vedle hlavního.
struct IconButton: View {
    @Environment(\.widgetActions) private var actions
    let command: WidgetCommand
    let title: String
    let symbol: String

    var body: some View {
        Themed { t in
            actions.make(command, AnyView(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.text)
                    .frame(width: 30, height: 30)
                    .background(t.panel, in: Circle())
                    .overlay(Circle().strokeBorder(t.line))
                    .contentShape(Circle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
            ))
        }
    }
}

extension WidgetCommand {
    /// Příkaz pro tlačítko (čas stisku doplní až akce při stisku).
    static func button(_ action: Action, subjectId: String? = nil, topic: String? = nil, modeId: String? = nil) -> WidgetCommand {
        WidgetCommand(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, action: action, subjectId: subjectId, topic: topic, modeId: modeId, at: 0)
    }
}

// MARK: - Drobné prvky

/// Nadpis sekce jako v seznamu aplikace („Dnes“, „Co teď?“) – tučně v barvě akcentu;
/// s `color` třeba tichý popisek („Další · 16:00“).
struct Caption: View {
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Themed { t in
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color ?? t.accent)
                .widgetAccentable(color == nil)
                .lineLimit(1)
        }
    }
}

/// List kalendáře s dnešním dnem (ikona stránky Dnes).
struct DayGlyph: View {
    let day: Int
    var size: CGFloat = 14

    var body: some View {
        Themed { t in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(t.accent)
                Text("\(day)").font(.system(size: size * 0.5, weight: .bold)).monospacedDigit()
                    .foregroundStyle(t.fullColor ? .white : t.bg).frame(maxHeight: .infinity).padding(.top, size * 0.12)
            }
            .frame(width: size * 0.9, height: size * 0.86)
            .widgetAccentable()
            .accessibilityHidden(true)
        }
    }
}

/// Políčko položky plánu jako v seznamu aplikace: hotové (plné), běží (výseč), čeká (obrys).
struct ItemCheck: View {
    enum State { case done, open, running(Double) }
    let state: State
    var size: CGFloat = 13

    var body: some View {
        Themed { t in
            let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            ZStack {
                switch state {
                case .done:
                    shape.fill(t.accent)
                    Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(t.fullColor ? .white : t.bg)
                case .open:
                    shape.strokeBorder(t.line, lineWidth: 1.3)
                case .running(let f):
                    shape.strokeBorder(t.accent, lineWidth: 1.3)
                    Circle().trim(from: 0, to: max(0.02, min(1, f))).stroke(t.accent, style: StrokeStyle(lineWidth: size * 0.3))
                        .rotationEffect(.degrees(-90)).frame(width: size * 0.3, height: size * 0.3)
                }
            }
            .frame(width: size, height: size)
            .widgetAccentable()
        }
    }
}

/// Délka „1 h 25 min“: čísla větší a tučnější, jednotky menší a šedé (jako `DurationText` v aplikaci).
struct BigDuration: View {
    let sec: Int
    let size: CGFloat

    var body: some View {
        Themed { t in
            Text(attributed(t)).lineLimit(1).minimumScaleFactor(0.7).accessibilityLabel(WidgetFormat.duration(sec))
        }
    }

    private func attributed(_ t: WidgetTheme) -> AttributedString {
        var out = AttributedString()
        for (i, part) in WidgetFormat.duration(sec).split(separator: " ").enumerated() {
            let isNumber = part.first?.isNumber == true
            var piece = AttributedString((i > 0 ? " " : "") + part)
            piece.font = isNumber ? .system(size: size, weight: .semibold).monospacedDigit() : .system(size: max(10, size * 0.5), weight: .medium)
            piece.foregroundColor = isNumber ? t.text : t.text2
            out += piece
        }
        return out
    }
}

/// Vodorovný ukazatel postupu.
struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        Themed { t in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.track)
                    Capsule().fill(color).frame(width: max(value > 0 ? 4 : 0, geo.size.width * min(1, max(0, value))))
                        .widgetAccentable()
                }
            }
        }
    }
}

/// Barevná tečka předmětu.
struct SubjectMark: View {
    let color: String
    var size: CGFloat = 7

    var body: some View {
        Themed { t in
            Circle().fill(t.subject(color)).frame(width: size, height: size).widgetAccentable()
        }
    }
}

extension EnvironmentValues {
    /// Náhledy mimo WidgetKit: živé hodiny (`Text(timerInterval:)`) se tam nevykreslí, ukáže se pevný čas.
    @Entry var widgetStaticClock = false
}

/// Odpočet nebo uplynulý čas běžící fáze – číslice běží živě samy, widget se kvůli nim nepřekresluje.
/// Pozastavený čas je tlumený.
struct LiveClock: View {
    @Environment(\.widgetStaticClock) private var staticClock
    let timer: WidgetSnapshot.TimerInfo
    let at: Int
    let size: CGFloat

    var body: some View {
        Themed { t in
            Group {
                if staticClock {
                    Text(WidgetFormat.clock(ms: timer.remaining(at: at) ?? timer.elapsed(at: at)))
                } else if timer.status == .running, let end = timer.phaseEnd, end > at {
                    Text(timerInterval: WidgetFormat.date(at)...WidgetFormat.date(end), countsDown: true)
                } else if timer.status == .running, timer.countsUp, let start = timer.virtualStart {
                    Text(WidgetFormat.date(start), style: .timer)
                } else {
                    Text(WidgetFormat.clock(ms: timer.remaining(at: at) ?? timer.elapsed(at: at)))
                }
            }
            .font(.system(size: size, weight: .light).monospacedDigit())
            .foregroundStyle(timer.status == .paused ? t.text3 : timer.isWork ? t.text : t.rest)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
        }
    }
}

// MARK: - Formáty

/// České formáty jako v aplikaci (`Format`), bez závislosti widgetu na výpočetním modulu.
enum WidgetFormat {
    static func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

    static func duration(_ sec: Int) -> String {
        let s = max(0, sec), h = s / 3600, m = (s % 3600) / 60
        if h == 0 { return "\(m) min" }
        return m > 0 ? "\(h) h \(m) min" : "\(h) h"
    }

    static func clock(ms: Int) -> String {
        let total = max(0, Int((Double(ms) / 1000).rounded())), h = total / 3600, m = (total % 3600) / 60, s = total % 60
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(two(m)):\(two(s))"
    }

    static func time(_ ms: Int) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date(ms))
        return "\(c.hour ?? 0):\((c.minute ?? 0) < 10 ? "0" : "")\(c.minute ?? 0)"
    }

    static let weekdays = ["po", "út", "st", "čt", "pá", "so", "ne"]
    static let weekdaysShort = ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"]

    /// „čt 22. 10.“
    static func day(_ ms: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let c = cal.dateComponents([.weekday, .day, .month], from: date(ms))
        let weekday = ((c.weekday ?? 2) + 5) % 7
        return "\(weekdays[weekday]) \(c.day ?? 1). \(c.month ?? 1)."
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        n == 1 ? one : (2...4).contains(n) ? few : many
    }

    /// „dnes“, „zítra“, „za 4 dny“.
    static func daysLeft(_ n: Int) -> String {
        n == 0 ? "dnes" : n == 1 ? "zítra" : "za \(n) \(plural(n, "den", "dny", "dní"))"
    }
}
