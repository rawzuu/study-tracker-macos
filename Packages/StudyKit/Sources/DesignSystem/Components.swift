import SwiftUI

/// Písmo: nadpisy a velká čísla patkovým písmem (New York – systémová patková písmo macOS,
/// na webu záložní k Newsreader), text systémovým.
public enum Typo {
    public static let pageTitle = Font.system(size: 40, weight: .regular, design: .serif)
    public static let sectionTitle = Font.system(size: 21, weight: .regular, design: .serif)
    public static func serifNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif).monospacedDigit()
    }
    public static let body = Font.system(size: 13.5)
    public static let small = Font.system(size: 12)
}

/// Hlavička stránky: velký patkový nadpis a podtitulek.
public struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(Typo.pageTitle)
                    .foregroundStyle(Palette.text)
                    .accessibilityIdentifier("page.title")
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(Typo.body).foregroundStyle(Palette.text2)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

/// Sekce bez rámečku: patkový nadpis a pod ním tenká linka (`.card` ve vzhledu Deník).
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typo.sectionTitle).foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory.font(Typo.small).foregroundStyle(Palette.text3)
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.lineStrong).frame(height: 1) }
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Řádek seznamu s tenkou linkou pod sebou.
public struct ListRow<Content: View>: View {
    let showsDivider: Bool
    let content: Content

    public init(divider: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsDivider = divider
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) { content }
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                if showsDivider { Rectangle().fill(Palette.line).frame(height: 1) }
            }
    }
}

/// Malý štítek (`.chip`).
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
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(tone == .accent ? Palette.accentSoft : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(tone == .neutral ? Palette.lineStrong : color.opacity(0.4)))
    }
}

/// Barevná značka a název předmětu.
public struct SubjectTag: View {
    let name: String
    let color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.subject(color)).frame(width: 8, height: 8)
            Text(name).lineLimit(1)
        }
    }
}

/// Tenký ukazatel průběhu (`.bar`). Nad 100 % zůstane plný.
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
                Capsule().fill(Palette.line)
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
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
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 20, weight: .light)).foregroundStyle(Palette.text3)
            Text(title).foregroundStyle(Palette.text2)
            footer.font(Typo.small).foregroundStyle(Palette.text3)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

/// Upozornění s ikonou (`.banner`).
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
                .foregroundStyle(tone == .bad ? Palette.danger : tone == .warn ? Palette.warn : Palette.text2)
            Text(text).font(Typo.body).foregroundStyle(Palette.text).frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 9)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.lineStrong))
    }
}

/// Délka „1 h 19 min“: čísla velká patkovým písmem, jednotky menší (`<Dur>` na webu).
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
            var piece = AttributedString((i > 0 ? (isNumber ? " " : "\u{2009}") : "") + part)
            piece.font = isNumber ? Typo.serifNumber(size) : .system(size: max(10, size * 0.4))
            piece.foregroundColor = isNumber ? Palette.text : Palette.text2
            out += piece
        }
        return out
    }
}

extension View {
    /// Pozadí stránky ve vzhledu Deník.
    public func pageBackground() -> some View {
        background(Palette.bg)
    }
}
