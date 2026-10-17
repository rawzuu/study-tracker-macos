import Core
import Foundation

/// Čtení kalendáře ve formátu iCalendar (.ics) – import školního rozvrhu (`src/lib/ical.ts` na webu).
/// Umí opakování (RRULE: DAILY/WEEKLY, INTERVAL, UNTIL, COUNT, BYDAY), výjimky (EXDATE), přesunuté
/// termíny (RECURRENCE-ID), zrušené akce (STATUS:CANCELLED) a časová pásma (TZID). Celodenní akce
/// (např. „zápočtový týden“) se přeskočí – nejsou to obsazené hodiny.
///
/// Výsledek musí být stejný jako na webu (kontrolní data `ical.json`), proto se tu napodobuje i
/// chování JavaScriptu: `Date.UTC`, `new Date(…)` v místním čase, `Number(…)` a `trim()`.
public enum ICal {
    public struct Result: Sendable {
        public let name: String
        public let events: [TimetableEvent]
        public let skippedAllDay: Int
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case notCalendar

        public var errorDescription: String? { "Soubor není kalendář ve formátu .ics." }
    }

    static let maxHorizonDays = 200 // opakování bez konce rozbalíme nejvýš na ~semestr
    static let maxSpanDays = 400 // ani s koncem dál než ~rok dopředu
    static let maxOccurrences = 2000
    static let dayMs = 86_400_000

    public static func parse(_ text: String, clock: StudyClock) throws(ParseError) -> Result {
        let lines = unfold(text)
        guard lines.contains(where: { $0.uppercased().hasPrefix("BEGIN:VCALENDAR") }) else { throw .notCalendar }
        let tz = Zones(clock: clock)

        var name = ""
        var raw: [RawEvent] = []
        var current: RawEvent?
        var depth = 0 // vnořené bloky (VALARM, VTIMEZONE) uvnitř VEVENT se přeskakují
        for line in lines {
            guard let (key, prop) = parseLine(line) else { continue }
            if key == "BEGIN" {
                if prop.value.uppercased() == "VEVENT" && current == nil {
                    current = RawEvent()
                    depth = 0
                } else if current != nil {
                    depth += 1
                }
                continue
            }
            if key == "END" {
                if let event = current, depth == 0, prop.value.uppercased() == "VEVENT" {
                    raw.append(event)
                    current = nil
                } else if current != nil {
                    depth -= 1
                }
                continue
            }
            if current != nil && depth == 0 {
                current!.add(key, prop)
            } else if current == nil && key == "X-WR-CALNAME" {
                name = unescapeText(prop.value)
            }
        }

        // Přesunuté termíny (RECURRENCE-ID) podle UID; bez hlavní akce se berou jako samostatné akce.
        var overrides: [(uid: String, events: [RawEvent])] = []
        var masters: [RawEvent] = []
        for e in raw {
            if e.first("RECURRENCE-ID") != nil {
                let uid = e.first("UID")?.value ?? ""
                if let i = overrides.firstIndex(where: { $0.uid == uid }) {
                    overrides[i].events.append(e)
                } else {
                    overrides.append((uid, [e]))
                }
            } else {
                masters.append(e)
            }
        }
        let masterUids = Set(masters.map { $0.first("UID")?.value ?? "" })
        for o in overrides where !masterUids.contains(o.uid) { masters += o.events }

        var events: [TimetableEvent] = []
        var skippedAllDay = 0
        func emit(_ e: RawEvent, _ startWall: Wall, _ base: DateValue, _ durationMs: Int) {
            let title = unescapeText(e.first("SUMMARY")?.value ?? "Bez názvu")
            let start = tz.ms(startWall, zone: base.tz, utc: base.utc)
            let series = normalizedSeries(title)
            events.append(TimetableEvent(raw: [
                "key": .string("\(series)|\(start)"), "series": .string(series), "title": .string(title),
                "location": .string(unescapeText(e.first("LOCATION")?.value ?? "")),
                "start": .number(Double(start)), "end": .number(Double(start + durationMs)),
            ]))
        }

        for e in masters {
            guard let sp = e.first("DTSTART"), let start = parseDate(sp) else { continue }
            if start.allDay {
                skippedAllDay += 1
                continue
            }
            if (e.first("STATUS")?.value ?? "").uppercased() == "CANCELLED" { continue }
            guard let duration = durationMs(e, start: start, tz: tz), duration > 0 else { continue }
            let uid = e.first("UID")?.value ?? ""

            var excluded = Set<Int>()
            for ex in e.all("EXDATE") {
                var params = ex.params
                if params["TZID"] == nil { params["TZID"] = start.tz ?? "" }
                for v in ex.value.split(separator: ",", omittingEmptySubsequences: false) {
                    guard var d = parseDate(Prop(value: String(v), params: params)) else { continue }
                    if d.allDay {
                        excluded.insert(utcMs(d.wall.y, d.wall.mo, d.wall.d))
                    } else {
                        if d.tz?.isEmpty == true { d.tz = nil }
                        excluded.insert(tz.ms(d))
                    }
                }
            }
            var moved: [Int: RawEvent] = [:]
            for o in overrides.first(where: { $0.uid == uid })?.events ?? [] {
                guard let ridProp = o.first("RECURRENCE-ID"), var rid = parseDate(ridProp) else { continue }
                if rid.tz == nil { rid.tz = start.tz }
                moved[tz.ms(rid)] = o
            }

            for w in expand(start, rrule: e.first("RRULE")?.value, tz: tz) {
                let t = tz.ms(w, zone: start.tz, utc: start.utc)
                if excluded.contains(t) || excluded.contains(utcMs(w.y, w.mo, w.d)) { continue }
                if let o = moved[t] {
                    if (o.first("STATUS")?.value ?? "").uppercased() == "CANCELLED" { continue }
                    guard let osp = o.first("DTSTART"), let os = parseDate(osp), !os.allDay else { continue }
                    emit(o, os.wall, os, durationMs(o, start: os, tz: tz) ?? duration)
                } else {
                    emit(e, w, start, duration)
                }
            }
        }

        let cs = Locale(identifier: "cs_CZ")
        events.sort { a, b in a.start != b.start ? a.start < b.start : a.title.compare(b.title, locale: cs) == .orderedAscending }
        // Stejný termín uvedený dvakrát (některé exporty to dělají) jen jednou.
        let unique = events.enumerated().filter { i, ev in i == 0 || ev.key != events[i - 1].key }.map(\.element)
        return Result(name: name, events: unique, skippedAllDay: skippedAllDay)
    }

    // MARK: - Řádky a vlastnosti

    struct Prop {
        var value: String
        var params: [String: String]
    }

    struct RawEvent {
        private var props: [String: [Prop]] = [:]

        mutating func add(_ key: String, _ prop: Prop) { props[key, default: []].append(prop) }
        func first(_ key: String) -> Prop? { props[key]?.first }
        func all(_ key: String) -> [Prop] { props[key] ?? [] }
    }

    /// Rozloží text na řádky a spojí pokračovací řádky (začínají mezerou nebo tabulátorem).
    static func unfold(_ text: String) -> [String] {
        var out: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.unicodeScalars.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += String(String.UnicodeScalarView(line.unicodeScalars.dropFirst()))
            } else if !line.jsTrimmed.isEmpty {
                out.append(String(line))
            }
        }
        return out
    }

    /// `NÁZEV;PARAM=hodnota:hodnota` – dvojtečka v uvozovkách v parametrech není oddělovač.
    static func parseLine(_ line: String) -> (String, Prop)? {
        let scalars = Array(line.unicodeScalars)
        var inQuote = false
        guard let colon = scalars.firstIndex(where: { ch in
            if ch == "\"" { inQuote.toggle() }
            return ch == ":" && !inQuote
        }) else { return nil }
        let head = String(String.UnicodeScalarView(scalars[..<colon]))
        let parts = head.split(separator: ";", omittingEmptySubsequences: false)
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "="), eq != p.startIndex else { continue }
            var value = Substring(p[p.index(after: eq)...])
            if value.hasPrefix("\"") { value = value.dropFirst() }
            if value.hasSuffix("\"") { value = value.dropLast() }
            params[p[..<eq].uppercased()] = String(value)
        }
        return (parts[0].uppercased(), Prop(value: String(String.UnicodeScalarView(scalars[(colon + 1)...])), params: params))
    }

    /// Text z hodnoty: `\n` → mezera, `\,` `\;` `\\` → znak, bez okrajových mezer.
    static func unescapeText(_ v: String) -> String {
        func replace(_ s: [Unicode.Scalar], _ match: (Unicode.Scalar) -> Unicode.Scalar?) -> [Unicode.Scalar] {
            var out: [Unicode.Scalar] = []
            var i = 0
            while i < s.count {
                if s[i] == "\\", i + 1 < s.count, let r = match(s[i + 1]) {
                    out.append(r)
                    i += 2
                } else {
                    out.append(s[i])
                    i += 1
                }
            }
            return out
        }
        let lines = replace(Array(v.unicodeScalars)) { $0 == "n" || $0 == "N" ? " " : nil }
        let chars = replace(lines) { [",", ";", "\\"].contains($0) ? $0 : nil }
        return String(String.UnicodeScalarView(chars)).jsTrimmed
    }

    /// Název řady: bez okrajových mezer a s jednou mezerou místo více (`normSeries` na webu).
    static func normalizedSeries(_ title: String) -> String {
        var out = ""
        var gap = false
        for ch in title.jsTrimmed.unicodeScalars {
            if jsWhitespaceScalars.contains(ch) {
                gap = true
            } else {
                if gap { out.append(" ") }
                gap = false
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: - Data a časy

    /// „Nástěnný“ čas: rok, měsíc 0–11, den, hodiny, minuty, sekundy (jako argumenty `Date.UTC`).
    struct Wall: Equatable {
        var y, mo, d, h, mi, s: Int
    }

    struct DateValue {
        var wall: Wall
        var allDay: Bool
        var utc: Bool
        var tz: String?
    }

    /// `YYYYMMDD` nebo `YYYYMMDDTHHMM[SS][Z]`.
    static func parseDate(_ p: Prop) -> DateValue? {
        let v = Array(p.value.jsTrimmed.unicodeScalars)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= v.count, range.allSatisfy({ ("0"..."9").contains(v[$0]) }) else { return nil }
            return range.reduce(0) { $0 * 10 + Int(v[$1].value - 48) }
        }
        guard let y = number(0..<4), let mo = number(4..<6), let d = number(6..<8) else { return nil }
        var wall = Wall(y: y, mo: mo - 1, d: d, h: 0, mi: 0, s: 0)
        var utc = false
        var hasTime = false
        if v.count > 8 {
            guard v[8] == "T", let h = number(9..<11), let mi = number(11..<13) else { return nil }
            hasTime = true
            wall.h = h
            wall.mi = mi
            var i = 13
            if let s = number(13..<15) {
                wall.s = s
                i = 15
            }
            if i < v.count, v[i] == "Z" {
                utc = true
                i += 1
            }
            guard i == v.count else { return nil }
        }
        return DateValue(wall: wall, allDay: p.params["VALUE"] == "DATE" || !hasTime, utc: utc, tz: p.params["TZID"])
    }

    /// `Date.UTC(y, mo, d, h, mi, s)` včetně přetečení měsíců a dnů (a roků 0–99 jako 1900–1999).
    static func utcMs(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Int {
        epochMs((0...99).contains(y) ? y + 1900 : y, mo, d, h, mi, s)
    }

    /// Okamžik v UTC bez zvláštního zacházení s roky 0–99 (tak čte JavaScript data `YYYY-MM-DD`).
    static func epochMs(_ year: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Int {
        let ym = year + Int((Double(mo) / 12).rounded(.down))
        let m = ((mo % 12) + 12) % 12
        let days = daysFromCivil(ym, m + 1, 1) + d - 1
        return (((days * 24 + h) * 60 + mi) * 60 + s) * 1000
    }

    /// Posun data o `days` dní v nástěnném čase (přes konce měsíců; čas dne zůstává).
    static func addWallDays(_ w: Wall, _ days: Int) -> Wall {
        let (y, m, d) = civilFromDays(utcMs(w.y, w.mo, w.d + days) / dayMs)
        return Wall(y: y, mo: m - 1, d: d, h: w.h, mi: w.mi, s: w.s)
    }

    /// 0 = pondělí … 6 = neděle
    static func weekday(_ w: Wall) -> Int {
        let days = utcMs(w.y, w.mo, w.d) / dayMs
        return ((days + 3) % 7 + 7) % 7 // 1. 1. 1970 byl čtvrtek
    }

    /// Dny od 1. 1. 1970 (proleptický gregoriánský kalendář).
    private static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z: Int) -> (Int, Int, Int) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// Převod nástěnného času na okamžik: v UTC, v pásmu TZID, nebo (bez pásma i s neznámým pásmem)
    /// v místním čase jako `new Date(…)` na webu.
    struct Zones {
        let clock: StudyClock

        func ms(_ v: DateValue) -> Int { ms(v.wall, zone: v.tz, utc: v.utc) }

        func ms(_ w: Wall, zone: String?, utc: Bool) -> Int {
            if utc { return utcMs(w.y, w.mo, w.d, w.h, w.mi, w.s) }
            if let zone, !zone.isEmpty, let tz = TimeZone(identifier: zone) {
                // Odhad s posunem v čase odhadu, pak oprava, pokud mezi nimi byla změna času (jako na webu).
                let guess = utcMs(w.y, w.mo, w.d, w.h, w.mi, w.s)
                let o1 = offset(tz, guess)
                var t = guess - o1
                let o2 = offset(tz, t)
                if o2 != o1 { t = guess - o2 }
                return t
            }
            var c = DateComponents()
            c.year = (0...99).contains(w.y) ? w.y + 1900 : w.y
            c.month = w.mo + 1
            c.day = w.d
            c.hour = w.h
            c.minute = w.mi
            c.second = w.s
            return clock.calendar.date(from: c).map(clock.ms) ?? utcMs(w.y, w.mo, w.d, w.h, w.mi, w.s)
        }

        private func offset(_ tz: TimeZone, _ t: Int) -> Int {
            tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(t) / 1000)) * 1000
        }
    }

    /// Doba trvání: z DTEND, jinak z DURATION (dny, hodiny, minuty).
    static func durationMs(_ e: RawEvent, start: DateValue, tz: Zones) -> Int? {
        if let endProp = e.first("DTEND") {
            return parseDate(endProp).map { tz.ms($0) - tz.ms(start) }
        }
        // /^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?/ – bez týdnů a sekund
        let v = Array((e.first("DURATION")?.value ?? "").unicodeScalars)
        guard v.first == "P" else { return nil }
        var i = 1
        func part(_ unit: Unicode.Scalar) -> Int? {
            var j = i, n = 0
            while j < v.count, ("0"..."9").contains(v[j]) {
                n = n * 10 + Int(v[j].value - 48)
                j += 1
            }
            guard j > i, j < v.count, v[j] == unit else { return nil }
            i = j + 1
            return n
        }
        let days = part("D")
        if i < v.count, v[i] == "T" { i += 1 }
        let hours = part("H")
        let minutes = part("M")
        guard days != nil || hours != nil || minutes != nil else { return nil }
        return (((days ?? 0) * 24 + (hours ?? 0)) * 60 + (minutes ?? 0)) * 60_000
    }

    // MARK: - Opakování

    private static let weekdays: [String: Int] = ["MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6]

    /// Začátky všech výskytů (nástěnný čas) podle RRULE.
    static func expand(_ start: DateValue, rrule: String?, tz: Zones) -> [Wall] {
        guard let rrule else { return [start.wall] }
        var r: [String: String] = [:]
        for part in rrule.split(separator: ";", omittingEmptySubsequences: false) {
            let kv = part.split(separator: "=", omittingEmptySubsequences: false)
            guard kv.count >= 2, !kv[0].isEmpty, !kv[1].isEmpty else { continue }
            r[kv[0].uppercased()] = String(kv[1])
        }
        guard let freq = r["FREQ"], freq == "WEEKLY" || freq == "DAILY" else { return [start.wall] } // jiné se v rozvrzích nevyskytují
        let interval = max(1, jsNumber(r["INTERVAL"] ?? "").flatMap { $0 == 0 ? nil : $0 } ?? 1)
        let count = r["COUNT"].map(jsNumber) ?? .infinity
        guard let count else { return [] } // COUNT, které není číslo: web nevrátí nic (porovnání s NaN)
        let startMs = tz.ms(start)
        var until = startMs + maxHorizonDays * dayMs
        if let u = r["UNTIL"].flatMap({ parseDate(Prop(value: $0, params: [:])) }) {
            until = u.allDay
                ? tz.ms(Wall(y: u.wall.y, mo: u.wall.mo, d: u.wall.d, h: 23, mi: 59, s: 59), zone: start.tz, utc: false)
                : tz.ms(u.wall, zone: start.tz, utc: u.utc)
        }
        until = min(until, startMs + maxSpanDays * dayMs)
        let limit = min(count, Double(maxOccurrences))

        var out: [Wall] = []
        func push(_ w: Wall) {
            let t = tz.ms(w, zone: start.tz, utc: start.utc)
            if t < startMs || t > until || Double(out.count) >= count { return }
            out.append(w)
        }
        if freq == "DAILY" {
            var k = 0.0
            while Double(out.count) < limit {
                let w = addWallDays(start.wall, Int(k))
                if tz.ms(w, zone: start.tz, utc: start.utc) > until { break }
                push(w)
                k += interval
            }
            return out
        }
        let days = (r["BYDAY"].map { $0.split(separator: ",", omittingEmptySubsequences: false).map { weekdays[String($0.suffix(2)).uppercased()] } }
            ?? [weekday(start.wall)])
            .compactMap { $0 }
            .sorted()
        let monday = addWallDays(start.wall, -weekday(start.wall))
        var week = 0.0
        while Double(out.count) < limit {
            let weekStart = addWallDays(monday, Int(week * 7))
            if tz.ms(weekStart, zone: start.tz, utc: start.utc) > until { break }
            for d in days {
                if Double(out.count) >= count { break }
                push(addWallDays(weekStart, d))
            }
            week += interval
        }
        return out
    }

    /// `Number(text)` z JavaScriptu pro hodnoty z RRULE; `nil` = NaN.
    static func jsNumber(_ text: String) -> Double? {
        let s = text.jsTrimmed
        switch s {
        case "": return 0
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = s.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            return UInt64(lower.dropFirst(2), radix: radix).map { Double($0) }
        }
        // Desetinné číslo s volitelným exponentem; Double(…) by přijal i „inf“ nebo „nan“.
        guard s.unicodeScalars.allSatisfy({ "0123456789+-.eE".unicodeScalars.contains($0) }) else { return nil }
        return Double(s)
    }
}

/// WhiteSpace a LineTerminator podle ECMAScriptu (`\s` v regulárních výrazech).
let jsWhitespaceScalars = Set("\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}".unicodeScalars)
