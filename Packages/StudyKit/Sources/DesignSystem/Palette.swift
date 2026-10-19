import AppKit
import SwiftUI

/// Barvy vzhledu „Seznam“: neutrální plochy (bílá / grafit), jeden modrý akcent pro výběr a akce,
/// červená jen pro „teď“ a blížící se termín. Ostatní barvu nesou předměty (z dat).
public enum Palette {
    /// Plocha stránky.
    public static let bg = dynamic(dark: 0x1E1F22, light: 0xFFFFFF)
    /// Druhá plocha (postranní sloupec, souhrn).
    public static let panel = dynamic(dark: 0x232427, light: 0xF7F7F8)
    /// Jemná výplň (štítky, pole, kolejnice ukazatelů).
    public static let panel2 = dynamic(dark: 0x2E2F33, light: 0xF0F1F3)
    /// Najetí myší a výběr.
    public static let panel3 = dynamic(dark: 0x37383D, light: 0xE6E7EA)
    /// Karta nad plochou (rozbalený běžící blok, plovoucí panely).
    public static let card = dynamic(dark: 0x2A2B2F, light: 0xFFFFFF)
    public static let line = dynamic(dark: 0x303136, light: 0xEBEBEE)
    public static let lineStrong = dynamic(dark: 0x3E3F44, light: 0xD8D8DD)
    public static let text = dynamic(dark: 0xECECEE, light: 0x1D1D1F)
    public static let text2 = dynamic(dark: 0xA3A4A9, light: 0x66666B)
    public static let text3 = dynamic(dark: 0x7E7F84, light: 0x88888D)
    public static let accent = dynamic(dark: 0x4C8DF6, light: 0x2F6FEB)
    public static let accentInk = dynamic(dark: 0xFFFFFF, light: 0xFFFFFF)
    public static let accentSoft = dynamic(dark: 0x4C8DF6, light: 0x2F6FEB, alpha: (0.16, 0.10))
    /// Pauza a odpočinek.
    public static let breakColor = dynamic(dark: 0x3FB8AA, light: 0x23968A)
    /// Hodnocení soustředění.
    public static let focus = dynamic(dark: 0x9B83E8, light: 0x7356CF)
    /// Splněný cíl.
    public static let success = dynamic(dark: 0x4CC06A, light: 0x2E9348)
    /// Termín se blíží (do deseti dní).
    public static let warn = dynamic(dark: 0xF08A4B, light: 0xC7581E)
    /// „Teď“, termín do tří dní, mazání.
    public static let danger = dynamic(dark: 0xFF6B63, light: 0xD93F3A)
    /// Obsazený čas z jiných kalendářů (šrafování).
    public static let hatch = dynamic(dark: 0xFFFFFF, light: 0x000000, alpha: (0.055, 0.045))

    /// Barva předmětu z dat (`#rrggbb`); neplatná hodnota → šedá jako na webu.
    public static func subject(_ hex: String) -> Color {
        Color(nsColor: NSColor(hex: hex) ?? NSColor(rgb: 0x9AA3AD))
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
