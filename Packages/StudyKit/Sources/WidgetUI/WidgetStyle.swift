import DesignSystem
import SwiftUI
import WidgetData
import WidgetKit

// Vzhled widgetů „Deník“: patková čísla, barvu nesou jen předměty, jantar jen pro akci a „teď“.
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
    var track: Color { fullColor ? Palette.fixed(Palette.panel3, scheme) : .primary.opacity(0.18) }
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

/// Tlačítko příkazu pro aplikaci (pozastavit, hotovo, začít…).
struct CommandButton: View {
    @Environment(\.widgetActions) private var actions
    let command: WidgetCommand
    let title: String
    let symbol: String
    var prominent = false
    var iconOnly = false

    var body: some View {
        actions.make(command, AnyView(label))
    }

    private var label: some View {
        Themed { t in
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: iconOnly ? 13 : 11, weight: .semibold))
                if !iconOnly { Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(prominent && t.fullColor ? t.accentInk : t.text)
            .padding(.horizontal, iconOnly ? 0 : 11)
            .frame(width: iconOnly ? 32 : nil, height: 28)
            .frame(maxWidth: iconOnly ? nil : .infinity)
            .background(prominent ? t.accent : t.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? .clear : t.line))
            .widgetAccentable(prominent)
            .accessibilityLabel(title)
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

/// Popisek sekce velkými písmeny („DNES“, „CO TEĎ?“).
struct Caption: View {
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Themed { t in
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(color ?? t.text3)
                .lineLimit(1)
        }
    }
}

/// Délka „1 h 25 min“: čísla patkovým písmem, jednotky menší (jako `DurationText` v aplikaci).
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
            var piece = AttributedString((i > 0 ? (isNumber ? " " : "\u{2009}") : "") + part)
            piece.font = isNumber ? .system(size: size, weight: .regular, design: .serif).monospacedDigit() : .system(size: max(10, size * 0.38))
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

/// Barevná značka předmětu.
struct SubjectMark: View {
    let color: String
    var size: CGFloat = 8

    var body: some View {
        Themed { t in
            RoundedRectangle(cornerRadius: size / 4).fill(t.subject(color)).frame(width: size, height: size).widgetAccentable()
        }
    }
}

/// Odpočet nebo uplynulý čas běžící fáze – číslice běží živě samy, widget se kvůli nim nepřekresluje.
struct LiveClock: View {
    let timer: WidgetSnapshot.TimerInfo
    let at: Int
    let size: CGFloat

    var body: some View {
        Themed { t in
            Group {
                if timer.status == .running, let end = timer.phaseEnd, end > at {
                    Text(timerInterval: WidgetFormat.date(at)...WidgetFormat.date(end), countsDown: true)
                } else if timer.status == .running, timer.countsUp, let start = timer.virtualStart {
                    Text(WidgetFormat.date(start), style: .timer)
                } else {
                    Text(WidgetFormat.clock(ms: timer.remaining(at: at) ?? timer.elapsed(at: at)))
                }
            }
            .font(.system(size: size, weight: .regular, design: .serif).monospacedDigit())
            .foregroundStyle(timer.isWork ? t.text : t.rest)
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
