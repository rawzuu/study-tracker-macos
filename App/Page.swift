import DesignSystem

/// Stránky aplikace – navigace webu (`PAGES` v `src/App.tsx`) bez Opakování,
/// které na Macu není (rozhodnutí uživatele 17. 10. 2026, viz docs/PLAN.md).
enum Page: String, CaseIterable, Identifiable, Hashable {
    case prehled, casovac, planovac
    case statistiky, report, reflexe, historie, uspechy
    case predmety, nastaveni

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prehled: "Dnes"
        case .casovac: "Časovač"
        case .planovac: "Kalendář"
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
        case .prehled, .casovac, .planovac: .learning
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
        case .statistiky, .report, .reflexe, .uspechy: "M5"
        case .nastaveni: "M6"
        }
    }

    /// Ikona v postranním panelu a v hlavičce stránky.
    func glyph(day: Int) -> PageGlyph {
        switch self {
        case .prehled: .today(day: day)
        case .casovac: .timer
        case .planovac: .calendar
        case .historie: .history
        case .predmety: .subjects
        case .nastaveni: .settings
        case .statistiky: .symbol("chart.bar")
        case .report: .symbol("doc.text")
        case .reflexe: .symbol("text.bubble")
        case .uspechy: .symbol("rosette")
        }
    }

    enum Group: String, CaseIterable {
        case learning = "Učení"
        case overview = "Přehledy"
        case setup = "Nastavení"
    }
}
