import Core
import Foundation

/// Odkaz, který rovnou spustí časovač – pro Zkratky, Siri nebo Spotlight (`deepLink.ts` na webu):
///
///     studytracker://casovac?start=1                      → poslední použitý předmět
///     studytracker://casovac?start=1&predmet=Matematika   → předmět podle názvu (stačí začátek, bez diakritiky)
///     …&tema=Derivace                                     → předvyplní téma
public struct TimerLink: Equatable, Sendable {
    public static let scheme = "studytracker"

    /// Hledaný název předmětu (`nil` = poslední použitý).
    public var subject: String?
    public var topic: String?

    public init(subject: String? = nil, topic: String? = nil) {
        self.subject = subject
        self.topic = topic
    }

    /// Jen `studytracker://casovac?start=…`; jiné odkazy (třeba jen otevření časovače) vrátí `nil`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let path = ((url.host ?? "") + url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path == "casovac" else { return nil }
        let query = Self.query(url)
        guard query.keys.contains("start") else { return nil }
        // Prázdná hodnota se bere jako chybějící (`p.get(…)` je v JS nepravdivé).
        subject = query["predmet"].flatMap { $0.isEmpty ? nil : $0 }
        topic = query["tema"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Je to odkaz na stránku časovače (i bez spuštění)?
    public static func isTimerPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && ((url.host ?? "") + url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "casovac"
    }

    /// Předmět k odkazu: podle názvu (celý, pak začátek), jinak poslední použitý, pokud pořád existuje.
    /// `nil` = bez předmětu se blok spustit nedá.
    public func subjectId(in doc: AppDocument, current: String) -> String? {
        let subjects = doc.alive(Subject.self).filter { !$0.archived }
        if let subject {
            let wanted = normalizedName(subject)
            let match = subjects.first { normalizedName($0.name) == wanted } ?? subjects.first { normalizedName($0.name).hasPrefix(wanted) }
            if let match { return match.id }
        }
        return subjects.contains { $0.id == current } ? current : nil
    }

    /// Parametry jako `URLSearchParams`: `+` je mezera, první výskyt klíče vyhrává.
    private static func query(_ url: URL) -> [String: String] {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let key = decode(parts[0])
            if out[key] == nil { out[key] = parts.count > 1 ? decode(parts[1]) : "" }
        }
        return out
    }
}

extension TimerState {
    /// Spustí blok z odkazu. Běžící blok nikdy nepřeruší; mezi bloky nejdřív ukončí sérii.
    public mutating func open(_ link: TimerLink, in doc: AppDocument, now: Int, presets: [TimerPreset]) {
        guard canSwitch, let subjectId = link.subjectId(in: doc, current: subjectId) else { return }
        setup(TimerSetup(subjectId: subjectId, topic: link.topic))
        start(now: now, mode: TimerMode.find(modeId, presets: presets))
    }
}
