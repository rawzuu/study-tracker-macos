import Foundation

/// Názvy bloků bez konkrétního tématu (vygenerované ranním plánem).
nonisolated(unsafe) private let noTopic = /(Nová látka|Blok podle plánu|Nedokončený blok|Po přednášce:.*|Anki:.*)/
/// Předpony z ranního plánu a „Co teď?“ – téma je až za nimi.
nonisolated(unsafe) private let topicPrefix = /(Opakování|Nové téma|Pokračovat|Příprava na zkoušku|Podle plánu):\s*/

/// Všechna témata z názvu bloku plánu (`blockTopics` v `src/lib/blockTopic.ts`):
/// „Opakování: Derivace, Limity +1“ → [„Derivace“, „Limity“], „Nové téma: Řady“ → [„Řady“],
/// „Opakování: Zápočet (−3 d)“ → [„Zápočet“]. Vlastní název bloku zůstane, jak je.
public func blockTopics(_ title: String) -> [String] {
    var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    for _ in 0..<3 {
        if t.wholeMatch(of: noTopic) != nil { return [] }
        guard let m = t.prefixMatch(of: topicPrefix) else { break }
        t = String(t[m.range.upperBound...])
            .replacing(/\s*\(−[0-9]+ d\)$/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // „+2“ na konci = další témata, která se do názvu nevešla – ta z názvu nezjistíme
        if m.1 == "Opakování" {
            return t.replacing(/\s\+[0-9]+$/, with: "")
                .components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
    return t.isEmpty ? [] : [t]
}
