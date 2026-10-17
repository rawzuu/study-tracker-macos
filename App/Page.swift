/// Stránky aplikace – stejné jako navigace webu (`PAGES` v `src/App.tsx`).
enum Page: String, CaseIterable, Identifiable, Hashable {
    case prehled, casovac, planovac, opakovani
    case statistiky, report, reflexe, historie, uspechy
    case predmety, nastaveni

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prehled: "Přehled"
        case .casovac: "Časovač"
        case .planovac: "Kalendář"
        case .opakovani: "Opakování"
        case .statistiky: "Statistiky"
        case .report: "Měsíční report"
        case .reflexe: "Reflexe"
        case .historie: "Historie"
        case .uspechy: "Úspěchy"
        case .predmety: "Předměty"
        case .nastaveni: "Nastavení"
        }
    }

    var group: Group {
        switch self {
        case .prehled, .casovac, .planovac, .opakovani: .learning
        case .statistiky, .report, .reflexe, .historie, .uspechy: .overview
        case .predmety, .nastaveni: .setup
        }
    }

    /// Milník, ve kterém stránka vznikne (docs/PLAN.md).
    var milestone: String {
        switch self {
        case .prehled, .historie, .predmety: "M1"
        case .casovac: "M2"
        case .planovac: "M3"
        case .opakovani: "M4"
        case .statistiky, .report, .reflexe, .uspechy: "M5"
        case .nastaveni: "M6"
        }
    }

    enum Group: String, CaseIterable {
        case learning = "Učení"
        case overview = "Přehledy"
        case setup = "Nastavení"
    }
}
