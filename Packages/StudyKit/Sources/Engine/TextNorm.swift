import Foundation

/// Název bez diakritiky, malými písmeny, jen `a–z0–9` oddělené mezerou (`norm` v `src/lib/timetable.ts`).
/// Podle toho se hledá předmět z odkazu („anatomie“ najde „Anatomie“, „fyziol“ najde „Fyziologie“).
public func normalizedName(_ s: String) -> String {
    let stripped = String(String.UnicodeScalarView(
        s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
    )).lowercased()
    var out = ""
    var gap = false
    for scalar in stripped.unicodeScalars {
        if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
            if gap && !out.isEmpty { out.append(" ") }
            gap = false
            out.unicodeScalars.append(scalar)
        } else {
            gap = true
        }
    }
    return out
}

extension String {
    /// `trim()` z JavaScriptu: bez mezer a konců řádků na začátku a na konci – i nedělitelné mezery a BOM.
    public var jsTrimmed: String { trimmingCharacters(in: jsWhitespace) }
}

/// WhiteSpace a LineTerminator podle ECMAScriptu (Zs, tabulátory, BOM, konce řádků).
private let jsWhitespace = CharacterSet(charactersIn:
    "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}"
        + "\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
