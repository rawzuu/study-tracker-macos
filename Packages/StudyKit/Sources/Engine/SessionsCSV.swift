import Core
import Foundation

/// Sezení do CSV (`sessionsToCsv` na webu): středník a BOM, aby je český Excel i Numbers otevřely správně.
public enum SessionsCSV {
    public static func make(_ doc: AppDocument, clock: StudyClock) -> String {
        var names: [String: String] = [:]
        for s in doc.records(Subject.self) { names[s.id] = s.name }
        let presets = Dictionary(doc.alive(TimerPreset.self).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let head: [Cell] = ["Datum", "Začátek", "Konec", "Předmět", "Téma", "Minuty", "Režim", "Soustředění", "Vyrušení", "Poznámka", "Vybavení"]
            .map(Cell.text)
        let rows = doc.alive(Session.self).stableSorted { $0.start < $1.start }.map { s -> [Cell] in
            [
                .text(clock.dayKey(s.start)),
                .text(Format.time(s.start, clock: clock)),
                .text(Format.time(s.end, clock: clock)),
                .text(names[s.subjectId] ?? ""),
                .text(s.topic),
                .text(minutes(s.raw.number("durationSec"))),
                .text(Format.modeName(s.mode, presets: presets)),
                .number(s.raw.number("focus").map(JSNumber.format) ?? ""),
                .number(s.raw.number("interruptions").map(JSNumber.format) ?? ""),
                .text(s.note),
                .text(s.recall ?? ""),
            ]
        }
        return "\u{FEFF}" + ([head] + rows).map { $0.map(\.csv).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
    }

    /// `(durationSec / 60).toFixed(1)` s desetinnou čárkou. printf zaokrouhlí přesnou binární hodnotu
    /// stejně jako `toFixed`, jen přesně „na půl“ (123,25) volí sudou číslici – `toFixed` vyšší.
    static func minutes(_ durationSec: Double?) -> String {
        guard let durationSec, !durationSec.isNaN else { return "NaN" }
        let x = durationSec / 60
        let scaled = x * 10
        // Je x·10 přesně k + 0,5? Zbytek po násobení spočítá fused multiply-add bez zaokrouhlení.
        let residual = (-scaled).addingProduct(x, 10)
        let text = if x >= 0, residual == 0, scaled - scaled.rounded(.down) == 0.5, scaled < 1e15 {
            String(format: "%.0f", scaled.rounded(.up)).withTenths
        } else {
            String(format: "%.1f", x)
        }
        return text.replacingOccurrences(of: ".", with: ",")
    }

    enum Cell {
        case text(String)
        case number(String)

        var csv: String {
            var s: String
            switch self {
            case .text(let t):
                s = t
                // Ochrana proti „formula injection“: text začínající =, +, -, @ by Excel spustil jako vzorec.
                if let first = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { s = "'" + s }
            case .number(let n):
                s = n
            }
            // Po skalárech – „\r\n“ je ve Swiftu jeden znak a mezi `\r` a `\n` by se nenašel.
            let quote = s.unicodeScalars.contains { "\";\n\r".unicodeScalars.contains($0) }
            return quote ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
    }
}

private extension String {
    /// „1233“ (desetiny) → „123.3“
    var withTenths: String {
        let padded = count < 2 ? String(repeating: "0", count: 2 - count) + self : self
        return padded.dropLast() + "." + padded.suffix(1)
    }
}
