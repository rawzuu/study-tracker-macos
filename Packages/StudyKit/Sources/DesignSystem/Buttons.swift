import SwiftUI

/// Tlačítka: zaoblený obdélník, hlavní akce modrá, pauza tyrkysová, ostatní s jemným obrysem.
public struct StudyButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// hlavní akce
        case primary
        /// pauza
        case rest
        /// s obrysem
        case normal
        /// bez obrysu
        case ghost
        /// smazání
        case danger
    }

    public enum Size: Sendable {
        case small, regular, large
    }

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let kind: Kind
    let size: Size

    public init(_ kind: Kind = .normal, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: kind == .primary || kind == .rest ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }

    private var height: CGFloat {
        switch size {
        case .small: 26
        case .regular: 30
        case .large: 38
        }
    }

    private var radius: CGFloat { size == .large ? 9 : 7 }

    private var padding: CGFloat {
        switch size {
        case .small: 10
        case .regular: 13
        case .large: 18
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: 12.5
        case .regular: 13
        case .large: 14
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Palette.accentInk
        case .rest: .white
        case .normal: Palette.text
        case .ghost: hovering && isEnabled ? Palette.text : Palette.text2
        case .danger: Palette.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        let active = (hovering || pressed) && isEnabled
        return switch kind {
        case .primary: Palette.accent.opacity(active ? 0.88 : 1)
        case .rest: Palette.breakColor.opacity(active ? 0.88 : 1)
        case .normal: active ? Palette.panel2 : Palette.card
        case .ghost: active ? Palette.panel3 : .clear
        case .danger: active ? Palette.danger.opacity(0.1) : Palette.card
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .rest: .clear
        case .normal: Palette.lineStrong
        case .ghost: .clear
        case .danger: Palette.lineStrong
        }
    }
}

extension ButtonStyle where Self == StudyButtonStyle {
    /// Hlavní akce.
    public static var primary: StudyButtonStyle { StudyButtonStyle(.primary) }

    public static func study(_ kind: StudyButtonStyle.Kind = .normal, size: StudyButtonStyle.Size = .regular) -> StudyButtonStyle {
        StudyButtonStyle(kind, size: size)
    }
}
