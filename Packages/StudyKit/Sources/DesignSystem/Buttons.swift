import SwiftUI

/// Tlačítka ve vzhledu Deník (`.btn` na webu): zaoblená, hlavní akce jantarová, pauza zelená.
public struct DenikButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// `.btn.primary` – hlavní akce
        case primary
        /// `.btn.break` – pauza
        case rest
        /// `.btn` – s obrysem
        case normal
        /// `.btn.ghost` – bez obrysu
        case ghost
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
            .background(background(pressed: configuration.isPressed), in: Capsule())
            .overlay(Capsule().strokeBorder(border))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }

    private var height: CGFloat {
        switch size {
        case .small: 28
        case .regular: 32
        case .large: 44
        }
    }

    private var padding: CGFloat {
        switch size {
        case .small: 11
        case .regular: 14
        case .large: 22
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: 12.5
        case .regular: 13
        case .large: 14.5
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Palette.accentInk
        case .rest: Color(red: 4 / 255, green: 20 / 255, blue: 11 / 255)
        case .normal: Palette.text
        case .ghost: hovering && isEnabled ? Palette.text : Palette.text2
        }
    }

    private func background(pressed: Bool) -> Color {
        let active = (hovering || pressed) && isEnabled
        return switch kind {
        case .primary: Palette.accent.opacity(active ? 0.88 : 1)
        case .rest: Palette.breakColor.opacity(active ? 0.88 : 1)
        case .normal: active ? Palette.panel2 : .clear
        case .ghost: active ? Palette.panel3 : .clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .rest: .clear
        case .normal: Palette.lineStrong
        case .ghost: .clear
        }
    }
}

extension ButtonStyle where Self == DenikButtonStyle {
    /// Hlavní akce (`.btn.primary`).
    public static var primary: DenikButtonStyle { DenikButtonStyle(.primary) }

    public static func denik(_ kind: DenikButtonStyle.Kind = .normal, size: DenikButtonStyle.Size = .regular) -> DenikButtonStyle {
        DenikButtonStyle(kind, size: size)
    }
}
