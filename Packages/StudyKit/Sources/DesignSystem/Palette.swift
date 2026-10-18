import AppKit
import SwiftUI

/// Barvy webového vzhledu „Deník“ (`src/styles/global.css`): teplá tmavá (primární) a papírová světlá.
/// Jeden jantarový akcent jen pro akce a „teď“; zelená = pauza/hotovo, modrá = soustředění.
public enum Palette {
    public static let bg = dynamic(dark: 0x12110F, light: 0xF6F3EE)
    public static let panel = dynamic(dark: 0x1A1916, light: 0xFBF9F5)
    public static let panel2 = dynamic(dark: 0x201E1B, light: 0xEFEBE4)
    public static let panel3 = dynamic(dark: 0x282622, light: 0xE6E1D8)
    public static let line = dynamic(dark: 0x22201D, light: 0xE4DFD6)
    public static let lineStrong = dynamic(dark: 0x302D29, light: 0xD3CCC0)
    public static let text = dynamic(dark: 0xEBE6DD, light: 0x1D1B18)
    public static let text2 = dynamic(dark: 0xA39D92, light: 0x5F5A52)
    public static let text3 = dynamic(dark: 0x837D73, light: 0x6E685F)
    public static let accent = dynamic(dark: 0xE3A641, light: 0x96620F)
    public static let accentInk = dynamic(dark: 0x1C1206, light: 0xFFFFFF)
    public static let accentSoft = dynamic(dark: 0xE3A641, light: 0x96620F, alpha: (0.12, 0.09))
    public static let breakColor = dynamic(dark: 0x8FAE8B, light: 0x4F7A4B)
    public static let focus = dynamic(dark: 0x9DB8D9, light: 0x4F6F93)
    public static let success = breakColor
    public static let warn = dynamic(dark: 0xD9925A, light: 0xA8571F)
    public static let danger = dynamic(dark: 0xE0786B, light: 0xB5473A)
    public static let heat0 = dynamic(dark: 0x1E1C19, light: 0xEBE6DD)

    /// Barva předmětu z dat (`#rrggbb`); neplatná hodnota → šedá jako na webu.
    public static func subject(_ hex: String) -> Color {
        Color(nsColor: NSColor(hex: hex) ?? NSColor(rgb: 0x9AA3AD))
    }

    /// Barva předmětu smíchaná s jinou barvou (`color-mix(in srgb, var(--c) …, …)` na webu);
    /// `amount` = podíl druhé barvy.
    public static func subject(_ hex: String, mixedWith other: UInt32, amount: Double) -> Color {
        let base = NSColor(hex: hex) ?? NSColor(rgb: 0x9AA3AD)
        return Color(nsColor: base.blended(withFraction: amount, of: NSColor(rgb: other)) ?? base)
    }

    /// Pevná barva pro daný vzhled (widgety a náhledy kreslí mimo okno aplikace, kde se dynamická barva
    /// nemusí přepnout se systémem).
    public static func fixed(_ color: Color, _ scheme: ColorScheme) -> Color {
        let dynamic = NSColor(color)
        var resolved = dynamic
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return Color(nsColor: resolved)
    }

    /// Text světlého vzhledu – s ním se v kalendáři ztmavují názvy předmětů na světlém pozadí.
    public static let lightText: UInt32 = 0x1D1B18

    private static func dynamic(dark: UInt32, light: UInt32, alpha: (Double, Double) = (1, 1)) -> Color {
        let d = NSColor(rgb: dark, alpha: alpha.0)
        let l = NSColor(rgb: light, alpha: alpha.1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init?(hex: String) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        if s.count == 3 { s = Substring(s.map { "\($0)\($0)" }.joined()) }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(rgb: value)
    }
}
