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
